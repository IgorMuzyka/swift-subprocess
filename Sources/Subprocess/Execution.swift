//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

#if canImport(Synchronization)
import Synchronization
#endif

/// An object that repersents a subprocess that has been
/// executed. You can use this object to send signals to the
/// child process as well as stream its output and error.
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
#if ContemporaryMacOS
@available(macOS 15, *)
#endif
public final class Execution<
    Output: OutputProtocol,
    Error: OutputProtocol
>: Sendable {
    /// The process identifier of the current execution
    public let processIdentifier: ProcessIdentifier

    internal let output: Output
    internal let error: Error
    internal let outputPipe: CreatedPipe
    internal let errorPipe: CreatedPipe
    #if canImport(Synchronization)
    internal let outputConsumptionState: AtomicBox<Atomic<OutputConsumptionState.RawValue>>
    #else
    internal let outputConsumptionState: AtomicBox<LockedState<OutputConsumptionState>>
    #endif
    #if os(Windows)
    internal let consoleBehavior: PlatformOptions.ConsoleBehavior

    init(
        processIdentifier: ProcessIdentifier,
        output: Output,
        error: Error,
        outputPipe: CreatedPipe,
        errorPipe: CreatedPipe,
        consoleBehavior: PlatformOptions.ConsoleBehavior
    ) {
        self.processIdentifier = processIdentifier
        self.output = output
        self.error = error
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        #if canImport(Synchronization)
        self.outputConsumptionState = AtomicBox(Atomic(0))
        #else
        self.outputConsumptionState = AtomicBox(LockedState(OutputConsumptionState(rawValue: 0)))
        #endif
        self.consoleBehavior = consoleBehavior
    }
    #else
    init(
        processIdentifier: ProcessIdentifier,
        output: Output,
        error: Error,
        outputPipe: CreatedPipe,
        errorPipe: CreatedPipe
    ) {
        self.processIdentifier = processIdentifier
        self.output = output
        self.error = error
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        #if canImport(Synchronization)
        self.outputConsumptionState = AtomicBox(Atomic(0))
        #else
        self.outputConsumptionState = AtomicBox(LockedState(OutputConsumptionState(rawValue: 0)))
        #endif
    }
    #endif  // os(Windows)
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
#if ContemporaryMacOS
@available(macOS 15, *)
#endif
extension Execution where Output == SequenceOutput {
    /// The standard output of the subprocess.
    ///
    /// Accessing this property will **fatalError** if this property was
    /// accessed multiple times. Subprocess communicates with parent process
    /// via pipe under the hood and each pipe can only be consumed once.
    public var standardOutput: some AsyncSequence<SequenceOutput.Buffer, any Swift.Error> {
        let consumptionState = self.outputConsumptionState.bitwiseXor(
            OutputConsumptionState.standardOutputConsumed,
        )

        guard consumptionState.contains(.standardOutputConsumed),
            let fd = self.outputPipe.readFileDescriptor
        else {
            fatalError("The standard output has already been consumed")
        }
        return AsyncBufferSequence(fileDescriptor: fd)
    }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
#if ContemporaryMacOS
@available(macOS 15, *)
#endif
extension Execution where Error == SequenceOutput {
    /// The standard error of the subprocess.
    ///
    /// Accessing this property will **fatalError** if this property was
    /// accessed multiple times. Subprocess communicates with parent process
    /// via pipe under the hood and each pipe can only be consumed once.
    public var standardError: some AsyncSequence<SequenceOutput.Buffer, any Swift.Error> {
        let consumptionState = self.outputConsumptionState.bitwiseXor(
            OutputConsumptionState.standardOutputConsumed,
        )

        guard consumptionState.contains(.standardErrorConsumed),
            let fd = self.errorPipe.readFileDescriptor
        else {
            fatalError("The standard output has already been consumed")
        }
        return AsyncBufferSequence(fileDescriptor: fd)
    }
}

// MARK: - Output Capture
internal enum OutputCapturingState<Output: Sendable, Error: Sendable>: Sendable {
    case standardOutputCaptured(Output)
    case standardErrorCaptured(Error)
}

internal struct OutputConsumptionState: OptionSet {
    typealias RawValue = UInt8

    internal let rawValue: UInt8

    internal init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let standardOutputConsumed: Self = .init(rawValue: 0b0001)
    static let standardErrorConsumed: Self = .init(rawValue: 0b0010)
}

internal typealias CapturedIOs<
    Output: Sendable,
    Error: Sendable
> = (standardOutput: Output, standardError: Error)

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
#if ContemporaryMacOS
@available(macOS 15, *)
#endif
extension Execution {
    internal func captureIOs() async throws -> CapturedIOs<
        Output.OutputType, Error.OutputType
    > {
        return try await withThrowingTaskGroup(
            of: OutputCapturingState<Output.OutputType, Error.OutputType>.self
        ) { group in
            group.addTask {
                let stdout = try await self.output.captureOutput(
                    from: self.outputPipe.readFileDescriptor
                )
                return .standardOutputCaptured(stdout)
            }
            group.addTask {
                let stderr = try await self.error.captureOutput(
                    from: self.errorPipe.readFileDescriptor
                )
                return .standardErrorCaptured(stderr)
            }

            var stdout: Output.OutputType!
            var stderror: Error.OutputType!
            while let state = try await group.next() {
                switch state {
                case .standardOutputCaptured(let output):
                    stdout = output
                case .standardErrorCaptured(let error):
                    stderror = error
                }
            }
            return (
                standardOutput: stdout,
                standardError: stderror
            )
        }
    }
}
