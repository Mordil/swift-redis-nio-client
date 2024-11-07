//===----------------------------------------------------------------------===//
//
// This source file is part of the RediStack open source project
//
// Copyright (c) 2019-2020 RediStack project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of RediStack project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// The `NIO.ChannelOutboundHandler.OutboundIn` type for `RedisCommandHandler`.
///
/// This holds the full command message to be sent to Redis, and an `NIO.EventLoopPromise` to be fulfilled when a response has been received.
/// - Important: This struct has _reference semantics_ due to the retention of the `NIO.EventLoopPromise`.
public struct RedisCommand {
    /// A message waiting to be sent to Redis. A full message contains a command keyword and its arguments stored as a single `RESPValue.array`.
    public let message: RESPValue
    /// A promise to be fulfilled with the sent message's response from Redis.
    public let responsePromise: EventLoopPromise<RESPValue>

    public init(message: RESPValue, responsePromise promise: EventLoopPromise<RESPValue>) {
        self.message = message
        self.responsePromise = promise
    }
}

/// An object that operates in a First In, First Out (FIFO) request-response cycle.
///
/// `RedisCommandHandler` is a `NIO.ChannelDuplexHandler` that sends `RedisCommand` instances to Redis,
/// and fulfills the command's `NIO.EventLoopPromise` as soon as a `RESPValue` response has been received from Redis.
public final class RedisCommandHandler {
    /// FIFO queue of promises waiting to receive a response value from a sent command.
    private var commandResponseQueue: CircularBuffer<EventLoopPromise<RESPValue>>
    private var state: State = .default

    deinit {
        if !self.commandResponseQueue.isEmpty {
            assertionFailure(
                "Command handler deinit when queue is not empty! Queue size: \(self.commandResponseQueue.count)"
            )
        }
    }

    /// - Parameter initialQueueCapacity: The initial queue size to start with. The default is `3`. `RedisCommandHandler` stores all
    ///         `RedisCommand.responsePromise` objects into a buffer, and unless you intend to execute several concurrent commands against Redis,
    ///         and don't want the buffer to resize, you shouldn't need to set this parameter.
    public init(initialQueueCapacity: Int = 3) {
        self.commandResponseQueue = CircularBuffer(initialCapacity: initialQueueCapacity)
    }

    private enum State {
        case `default`
        case draining(EventLoopPromise<Void>?)
        case error(Error)
    }
}

// MARK: ChannelInboundHandler

extension RedisCommandHandler: ChannelInboundHandler {
    public typealias InboundIn = RESPValue

    /// Invoked by SwiftNIO when an error has been thrown. The command queue will be drained
    ///     with each promise in the queue being failed with the error thrown.
    ///
    /// See `NIO.ChannelInboundHandler.errorCaught(context:error:)`
    /// - Important: This will also close the socket connection to Redis.
    /// - Note:`RedisMetrics.commandFailureCount` is **not** incremented from this method.
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        self._failCommandQueue(because: error)
        context.close(promise: nil)
    }

    /// Invoked by SwiftNIO when the channel's active state has changed, such as when it is closed. The command queue will be drained
    ///     with each promise in the queue being failed from a connection closed error.
    ///
    /// See `NIO.ChannelInboundHandler.channelInactive(context:)`
    /// - Note: `RedisMetrics.commandFailureCount` is **not** incremented from this method.
    public func channelInactive(context: ChannelHandlerContext) {
        self.state = .error(RedisClientError.connectionClosed)
        self._failCommandQueue(because: RedisClientError.connectionClosed)
    }

    private func _failCommandQueue(because error: Error) {
        self.state = .error(error)
        let queue = self.commandResponseQueue
        self.commandResponseQueue.removeAll()
        for element in queue {
            element.fail(error)
        }
    }

    /// Invoked by SwiftNIO when a read has been fired from earlier in the response chain.
    ///
    /// This forwards the decoded `RESPValue` response message to the promise waiting to be fulfilled at the front of the command queue.
    /// - Note: `RedisMetrics.commandFailureCount` and `RedisMetrics.commandSuccessCount` are incremented from this method.
    ///
    /// See `NIO.ChannelInboundHandler.channelRead(context:data:)`
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = self.unwrapInboundIn(data)

        guard let leadPromise = self.commandResponseQueue.popFirst() else { return }

        switch value {
        case .error(let e):
            leadPromise.fail(e)
            RedisMetrics.commandFailureCount.increment()

        default:
            leadPromise.succeed(value)
            RedisMetrics.commandSuccessCount.increment()
        }

        switch self.state {
        case .draining(let promise):
            if self.commandResponseQueue.isEmpty {
                context.close(mode: .all, promise: promise)
            }

        case .error, .`default`:
            break
        }
    }
}

// MARK: ChannelOutboundHandler

extension RedisCommandHandler: ChannelOutboundHandler {
    /// See `NIO.ChannelOutboundHandler.OutboundIn`
    public typealias OutboundIn = RedisCommand
    /// See `NIO.ChannelOutboundHandler.OutboundOut`
    public typealias OutboundOut = RESPValue

    /// Invoked by SwiftNIO when a `write` has been requested on the `Channel`.
    ///
    /// This unwraps a `RedisCommand`, storing the `NIO.EventLoopPromise` in a command queue,
    /// to fulfill later with the response to the command that is about to be sent through the `NIO.Channel`.
    ///
    /// See `NIO.ChannelOutboundHandler.write(context:data:promise:)`
    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let commandContext = self.unwrapOutboundIn(data)

        switch self.state {
        case let .error(e):
            commandContext.responsePromise.fail(e)

        case .draining:
            commandContext.responsePromise.fail(RedisClientError.connectionClosed)

        case .default:
            self.commandResponseQueue.append(commandContext.responsePromise)
            context.write(
                self.wrapOutboundOut(commandContext.message),
                promise: promise
            )
        }
    }

    /// Listens for ``RedisGracefulConnectionCloseEvent``. If such an event is received the handler will wait
    /// until all currently running commands have returned. Once all requests are fulfilled the handler will close the channel.
    ///
    /// If a command is sent on the channel, after the ``RedisGracefulConnectionCloseEvent`` was scheduled,
    /// the command will be failed with a ``RedisClientError/connectionClosed``.
    ///
    /// See `NIO.ChannelOutboundHandler.triggerUserOutboundEvent(context:event:promise:)`
    public func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case is RedisGracefulConnectionCloseEvent:
            switch self.state {
            case .default:
                if self.commandResponseQueue.isEmpty {
                    self.state = .error(RedisClientError.connectionClosed)
                    context.close(mode: .all, promise: promise)
                } else {
                    self.state = .draining(promise)
                }

            case .error, .draining:
                promise?.succeed(())
                break
            }

        default:
            context.triggerUserOutboundEvent(event, promise: promise)
        }
    }
}

/// A channel event that informs the ``RedisCommandHandler`` that it should close the channel gracefully
public struct RedisGracefulConnectionCloseEvent {
    /// Creates a ``RedisGracefulConnectionCloseEvent``
    public init() {}
}
