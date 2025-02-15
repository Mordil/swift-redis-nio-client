//===----------------------------------------------------------------------===//
//
// This source file is part of the RediStack open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the RediStack project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of RediStack project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIOCore

/// `ConnectionPool` is RediStack's internal representation of a pool of Redis connections.
///
/// `ConnectionPool` has two major jobs. Its first job is to reduce the latency cost of making a new Redis query by
/// keeping a number of connections active and warm. This improves the odds that any given attempt to make a query
/// will find an idle connection and avoid needing to create a new one.
///
/// The second job is to handle cluster management. In some cases there will be a cluster of Redis machines available,
/// any of which would be suitable for a query. The connection pool can be used to manage this cluster by automatically
/// spreading connection load across it.
///
/// In RediStack, each `ConnectionPool` is tied to a single event loop. All of its state may only be accessed from that
/// event loop. However, it does provide an API that is safe to call from any event loop. In latency sensitive applications,
/// it is a good idea to keep pools local to event loops. This can cause more connections to be made than if the pool was shared,
/// but it further reduces the latency cost of each database operation. In less latency sensitive applications, the pool can be
/// shared across all loops.
///
/// This `ConnectionPool` uses an MRU strategy for managing connections: the most recently used free connection is the one that
/// is used for a query. This system reduces the risk that a connection will die in the gap between being removed from the pool
/// and being used, at the cost of incurring more reconnects under low load. Of course, when we're under low load we don't
/// really care how many reconnects there are.
internal final class ConnectionPool {
    /// A function used to create Redis connections.
    private let connectionFactory: (EventLoop) -> EventLoopFuture<RedisConnection>

    /// A stack of connections that are active and suitable for use by clients.
    private(set) var availableConnections: ArraySlice<RedisConnection>

    /// A buffer of users waiting for connections to be handed over.
    private var connectionWaiters: CircularBuffer<Waiter>

    /// The event loop we're on.
    private let loop: EventLoop

    /// The exponential backoff factor for connection attempts.
    internal let backoffFactor: Float32

    /// The initial delay for backing off a reconnection attempt.
    internal let initialBackoffDelay: TimeAmount

    /// The maximum number of connections the pool will preserve. Additional connections will be made available
    /// past this limit if `leaky` is set to `true`, but they will not be persisted in the pool once used.
    internal let maximumConnectionCount: Int

    /// The minimum number of connections the pool will keep alive. If a connection is disconnected while in the
    /// pool such that the number of connections drops below this number, the connection will be re-established.
    internal let minimumConnectionCount: Int

    /// The number of connection attempts currently outstanding.
    private var pendingConnectionCount: Int

    /// The number of connections that have been handed out to users and are in active use.
    private(set) var leasedConnectionCount: Int

    /// Whether this connection pool is "leaky".
    ///
    /// The difference between a leaky and non-leaky connection pool is their behaviour when the pool is currently
    /// entirely in-use. For a leaky pool, if a connection is requested and none are available, a new connection attempt
    /// will be made and the connection will be passed to the user. For a non-leaky pool, the user will wait for a connection
    /// to be returned to the pool.
    internal let leaky: Bool

    /// The current state of this connection pool.
    private var state: State

    /// The number of connections that are "live": either in the pool, in the process of being created, or
    /// leased to users.
    private var activeConnectionCount: Int {
        self.availableConnections.count + self.pendingConnectionCount + self.leasedConnectionCount
    }

    /// Whether a connection can be added into the availableConnections pool when it's returned. This is true
    /// for non-leaky pools if the sum of availableConnections and leased connections is less than max connections,
    /// and for leaky pools if the number of availableConnections is less than max connections (as we went to all
    /// the effort to create the connection, we may as well keep it).
    /// Note that this means connection attempts in flight may not be used for anything. This is ok!
    private var canAddConnectionToPool: Bool {
        if self.leaky {
            return self.availableConnections.count < self.maximumConnectionCount
        } else {
            return (self.availableConnections.count + self.leasedConnectionCount) < self.maximumConnectionCount
        }
    }

    internal init(
        maximumConnectionCount: Int,
        minimumConnectionCount: Int,
        leaky: Bool,
        loop: EventLoop,
        backgroundLogger: Logger,
        connectionBackoffFactor: Float32 = 2,
        initialConnectionBackoffDelay: TimeAmount = .milliseconds(100),
        connectionFactory: @escaping (EventLoop) -> EventLoopFuture<RedisConnection>
    ) {
        guard minimumConnectionCount <= maximumConnectionCount else {
            backgroundLogger.critical("pool's minimum connection count is higher than the maximum")
            preconditionFailure("Minimum connection count must not exceed maximum")
        }

        self.connectionFactory = connectionFactory
        self.availableConnections = []
        self.availableConnections.reserveCapacity(maximumConnectionCount)

        // 8 is a good number to skip the first few buffer resizings
        self.connectionWaiters = CircularBuffer(initialCapacity: 8)
        self.loop = loop
        self.backoffFactor = connectionBackoffFactor
        self.initialBackoffDelay = initialConnectionBackoffDelay

        self.maximumConnectionCount = maximumConnectionCount
        self.minimumConnectionCount = minimumConnectionCount
        self.pendingConnectionCount = 0
        self.leasedConnectionCount = 0
        self.leaky = leaky
        self.state = .active
    }

    /// Activates this connection pool by causing it to populate its backlog of connections.
    func activate(logger: Logger) {
        if self.loop.inEventLoop {
            self.refillConnections(logger: logger)
        } else {
            self.loop.execute {
                self.refillConnections(logger: logger)
            }
        }
    }

    /// Deactivates this connection pool. Once this is called, no further connections can be obtained
    /// from the pool. Leased connections are not deactivated and can continue to be used. All waiters
    /// are failed with a pool is closed error.
    func close(promise: EventLoopPromise<Void>? = nil, logger: Logger) {
        if self.loop.inEventLoop {
            self.closePool(promise: promise, logger: logger)
        } else {
            self.loop.execute {
                self.closePool(promise: promise, logger: logger)
            }
        }
    }

    func leaseConnection(deadline: NIODeadline, logger: Logger) -> EventLoopFuture<RedisConnection> {
        if self.loop.inEventLoop {
            return self._leaseConnection(deadline, logger: logger)
        } else {
            return self.loop.flatSubmit {
                self._leaseConnection(deadline, logger: logger)
            }
        }
    }

    func returnConnection(_ connection: RedisConnection, logger: Logger) {
        if self.loop.inEventLoop {
            self._returnLeasedConnection(connection, logger: logger)
        } else {
            return self.loop.execute {
                self._returnLeasedConnection(connection, logger: logger)
            }
        }
    }
}

// MARK: Internal implementation
extension ConnectionPool {
    /// Ensures that sufficient connections are available in the pool.
    private func refillConnections(logger: Logger) {
        self.loop.assertInEventLoop()

        guard case .active = self.state else {
            // Don't do anything to refill connections if we're not in the active state: we don't care.
            return
        }

        var neededConnections = self.minimumConnectionCount - self.activeConnectionCount
        logger.trace(
            "refilling connections",
            metadata: [
                RedisLogging.MetadataKeys.connectionCount: "\(neededConnections)"
            ]
        )
        while neededConnections > 0 {
            self._createConnection(backoff: self.initialBackoffDelay, startIn: .nanoseconds(0), logger: logger)
            neededConnections -= 1
        }
    }

    private func _createConnection(backoff: TimeAmount, startIn delay: TimeAmount, logger: Logger) {
        self.loop.assertInEventLoop()
        self.pendingConnectionCount += 1

        self.loop.scheduleTask(in: delay) {
            self.connectionFactory(self.loop)
                .whenComplete { result in
                    self.loop.preconditionInEventLoop()

                    self.pendingConnectionCount -= 1

                    switch result {
                    case .success(let connection):
                        self.connectionCreationSucceeded(connection, logger: logger)

                    case .failure(let error):
                        self.connectionCreationFailed(error, backoff: backoff, logger: logger)
                    }
                }
        }
    }

    private func connectionCreationSucceeded(_ connection: RedisConnection, logger: Logger) {
        self.loop.assertInEventLoop()

        logger.trace(
            "connection creation succeeded",
            metadata: [
                RedisLogging.MetadataKeys.connectionID: "\(connection.id)"
            ]
        )

        switch self.state {
        case .closing:
            // We don't want this anymore, drop it.
            self.closeConnectionForShutdown(connection)
        case .closed:
            // This is programmer error, we shouldn't have entered this state.
            logger.critical(
                "new connection created on a closed pool",
                metadata: [
                    RedisLogging.MetadataKeys.connectionID: "\(connection.id)"
                ]
            )
            preconditionFailure("In closed while pending connections were outstanding.")
        case .active:
            // Great, we want this. We'll be "returning" it to the pool. First,
            // attach the close callback to it.
            connection.channel.closeFuture.whenComplete { _ in self.poolConnectionClosed(connection, logger: logger) }
            self._returnConnection(connection, logger: logger)
        }
    }

    private func connectionCreationFailed(_ error: Error, backoff: TimeAmount, logger: Logger) {
        self.loop.assertInEventLoop()

        logger.error(
            "failed to create connection for pool",
            metadata: [
                RedisLogging.MetadataKeys.error: "\(error)"
            ]
        )

        switch self.state {
        case .active:
            break  // continue further down

        case .closing(let remaining, let promise):
            if remaining == 1 {
                self.state = .closed
                promise?.succeed()
            } else {
                self.state = .closing(remaining: remaining - 1, promise)
            }
            return

        case .closed:
            preconditionFailure("Invalid state: \(self.state)")
        }

        // Ok, we're still active. Before we do anything, we want to check whether anyone is still waiting
        // for this connection. Waiters can time out: if they do, we can just give up this connection.
        // We know folks need this in the following conditions:
        //
        // 1. For non-leaky buckets, we need this reconnection if there are any waiters AND the number of active connections (which includes
        //     pending connection attempts) is less than max connections
        // 2. For leaky buckets, we need this reconnection if connectionWaiters.count is greater than the number of pending connection attempts.
        // 3. For either kind, if the number of active connections is less than the minimum.
        let shouldReconnect: Bool
        if self.leaky {
            shouldReconnect =
                (self.connectionWaiters.count > self.pendingConnectionCount)
                || (self.minimumConnectionCount > self.activeConnectionCount)
        } else {
            shouldReconnect =
                (!self.connectionWaiters.isEmpty && self.maximumConnectionCount > self.activeConnectionCount)
                || (self.minimumConnectionCount > self.activeConnectionCount)
        }

        guard shouldReconnect else {
            logger.debug("not reconnecting due to sufficient existing connection attempts")
            return
        }

        // Ok, we need the new connection.
        let newBackoff = TimeAmount.nanoseconds(Int64(Float32(backoff.nanoseconds) * self.backoffFactor))
        logger.debug(
            "reconnecting after failed connection attempt",
            metadata: [
                RedisLogging.MetadataKeys.poolConnectionRetryBackoff: "\(backoff)ns",
                RedisLogging.MetadataKeys.poolConnectionRetryNewBackoff: "\(newBackoff)ns",
            ]
        )
        self._createConnection(backoff: newBackoff, startIn: backoff, logger: logger)
    }

    /// A connection that was monitored by this pool has been closed.
    private func poolConnectionClosed(_ connection: RedisConnection, logger: Logger) {
        self.loop.preconditionInEventLoop()

        // We need to work out what kind of connection this was. This is easily done: if the connection is in the
        // availableConnections list then it's an available connection, otherwise it's a leased connection.
        // For leased connections we don't do any work here: those connections are required to be returned to the pool,
        // so we'll handle them when they come back.
        // We just do a linear scan here because the pool is rarely likely to be very large, so the cost of a fancier
        // datastructure is simply not worth it. Even the cost of shuffling elements around is low.
        if let index = self.availableConnections.firstIndex(where: { $0 === connection }) {
            // It's in the available set. Remove it.
            self.availableConnections.remove(at: index)
        }

        // We may need to refill connections to keep at our minimum connection count.
        self.refillConnections(logger: logger)
    }

    private func leaseConnection(_ connection: RedisConnection, to waiter: Waiter) {
        self.loop.assertInEventLoop()
        self.leasedConnectionCount += 1
        waiter.succeed(connection)
    }

    private func closePool(promise: EventLoopPromise<Void>?, logger: Logger) {
        self.loop.preconditionInEventLoop()

        switch self.state {
        case .active:
            self.state = .closing(remaining: self.activeConnectionCount, promise)

        case .closing(let count, let existingPromise):
            if let existingPromise = existingPromise {
                existingPromise.futureResult.cascade(to: promise)
            } else {
                self.state = .closing(remaining: count, promise)
            }
            return

        case .closed:
            promise?.succeed()
            return
        }

        // We also cancel all pending leases.
        while let pendingLease = self.connectionWaiters.popFirst() {
            pendingLease.fail(RedisConnectionPoolError.poolClosed)
        }

        if self.activeConnectionCount == 0 {
            // That was all the connections, so this is now closed.
            logger.trace("pool is now closed")
            self.state = .closed
            promise?.succeed()
            return
        }

        // To close the pool we need to drop all active connections.
        let connections = self.availableConnections
        self.availableConnections = []
        for connection in connections {
            self.closeConnectionForShutdown(connection)
        }
    }

    /// This is the on-thread implementation for leasing connections out to users. Here we work out how to get a new
    /// connection, and attempt to do so.
    private func _leaseConnection(_ deadline: NIODeadline, logger: Logger) -> EventLoopFuture<RedisConnection> {
        self.loop.assertInEventLoop()

        guard case .active = self.state else {
            logger.trace("attempted to lease connection from closed pool")
            return self.loop.makeFailedFuture(RedisConnectionPoolError.poolClosed)
        }

        var waiter = Waiter(result: self.loop.makePromise())

        // Loop over the available connections. It's possible some of these are dead but we don't know
        // that yet, so double-check. Leave the dead ones there: we'll get them later.
        while let connection = self.availableConnections.popLast() {
            if connection.isConnected {
                logger.trace(
                    "found available connection",
                    metadata: [
                        RedisLogging.MetadataKeys.connectionID: "\(connection.id)"
                    ]
                )
                self.leaseConnection(connection, to: waiter)
                return waiter.futureResult
            }
        }

        // Ok, we didn't have any available connections. We're going to have to wait. Set our timeout.
        waiter.scheduleDeadline(loop: self.loop, deadline: deadline) {
            logger.trace("connection not found in time")
            // The waiter timed out. We're going to fail the promise and remove the waiter.
            waiter.fail(RedisConnectionPoolError.timedOutWaitingForConnection)

            guard let index = self.connectionWaiters.firstIndex(where: { $0.id == waiter.id }) else { return }
            self.connectionWaiters.remove(at: index)
        }
        self.connectionWaiters.append(waiter)

        // Ok, we have connection targets. If the number of active connections is
        // below the max, or the pool is leaky, we can create a new connection. Otherwise, we just have
        // to wait for a connection to come back.
        if self.activeConnectionCount < self.maximumConnectionCount || self.leaky {
            logger.trace("creating new connection")
            self._createConnection(backoff: self.initialBackoffDelay, startIn: .nanoseconds(0), logger: logger)
        }

        return waiter.futureResult
    }

    /// This is the on-thread implementation for returning connections to the pool that were previously leased to users.
    /// It delegates to `_returnConnection`.
    private func _returnLeasedConnection(_ connection: RedisConnection, logger: Logger) {
        self.loop.assertInEventLoop()
        self.leasedConnectionCount -= 1

        switch self.state {
        case .active:
            self._returnConnection(connection, logger: logger)

        case .closing:
            return self.closeConnectionForShutdown(connection)

        case .closed:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    /// This is the on-thread implementation for returning connections to the pool. Here we work out what to do with a newly-acquired
    /// connection.
    private func _returnConnection(_ connection: RedisConnection, logger: Logger) {
        self.loop.assertInEventLoop()
        precondition(self.state.isActive)

        guard connection.isConnected else {
            // This connection isn't active anymore. We'll dump it and potentially kick off a reconnection.
            self.refillConnections(logger: logger)
            return
        }

        // If anyone is waiting for a connection, let's give them this one. Otherwise, if there's room
        // in the pool, we'll put it there. Otherwise, we'll close it.
        if let waiter = self.connectionWaiters.popFirst() {
            self.leaseConnection(connection, to: waiter)
        } else if self.canAddConnectionToPool {
            self.availableConnections.append(connection)
        } else if let evictable = self.availableConnections.popFirst() {
            // We have at least one pooled connection. The returned is more recently active, so kick out the pooled
            // connection in favour of this one and close the recently evicted one.
            self.availableConnections.append(connection)
            _ = evictable.close()
        } else {
            // We don't need it, close it.
            _ = connection.close()
        }
    }

    private func closeConnectionForShutdown(_ connection: RedisConnection) {
        connection.close().whenComplete { _ in
            self.loop.preconditionInEventLoop()

            switch self.state {
            case .closing(let remaining, let promise):
                if remaining == 1 {
                    self.state = .closed
                    promise?.succeed()
                } else {
                    self.state = .closing(remaining: remaining - 1, promise)
                }

            case .closed, .active:
                // The state must not change if we are closing a connection, while we are
                // closing the pool.
                preconditionFailure("Invalid state: \(self.state)")
            }
        }
    }
}

extension ConnectionPool {
    fileprivate enum State {
        /// The connection pool is in active use.
        case active

        /// The user has requested the connection pool to close, but there are still active connections leased to users
        /// and in the pool.
        case closing(remaining: Int, EventLoopPromise<Void>?)

        /// The connection pool is closed: no connections are outstanding
        case closed

        var isActive: Bool {
            switch self {
            case .active:
                return true
            case .closing, .closed:
                return false
            }
        }
    }
}

extension ConnectionPool {
    /// A representation of a single waiter.
    struct Waiter {
        private var timeoutTask: Scheduled<Void>?

        private var result: EventLoopPromise<RedisConnection>

        var id: ObjectIdentifier {
            ObjectIdentifier(self.result.futureResult)
        }

        var futureResult: EventLoopFuture<RedisConnection> {
            self.result.futureResult
        }

        init(result: EventLoopPromise<RedisConnection>) {
            self.result = result
        }

        mutating func scheduleDeadline(loop: EventLoop, deadline: NIODeadline, _ onTimeout: @escaping () -> Void) {
            assert(self.timeoutTask == nil)
            self.timeoutTask = loop.scheduleTask(deadline: deadline, onTimeout)
        }

        func succeed(_ connection: RedisConnection) {
            self.timeoutTask?.cancel()
            self.result.succeed(connection)
        }

        func fail(_ error: Error) {
            self.timeoutTask?.cancel()
            self.result.fail(error)
        }
    }
}
