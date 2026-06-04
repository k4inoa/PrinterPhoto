import Foundation
import Network
import UIKit

struct EscPosPrinterClient {
    enum ClientError: Error {
        case invalidPort
        case connectionFailed
        case sendFailed
    }

    private let renderer = EscPosImageRenderer()

    func print(image: UIImage, to printer: DiscoveredPrinter, paperWidth: PaperWidth) async throws {
        let data = try renderer.printData(from: image, paperWidth: paperWidth)
        let port = printer.ports.first(where: { $0 == 9100 }) ?? printer.ports.first ?? 9100
        try await send(data, host: printer.host, port: port)
    }

    func send(_ data: Data, host: String, port: Int) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ClientError.invalidPort
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                final class State {
                    var resumed = false
                }

                let state = State()
                func resume(_ result: Result<Void, Error>) {
                    guard !state.resumed else { return }
                    state.resumed = true
                    connection.cancel()
                    continuation.resume(with: result)
                }

                connection.stateUpdateHandler = { newState in
                    switch newState {
                    case .ready:
                        connection.send(content: data, completion: .contentProcessed { error in
                            if let error {
                                resume(.failure(error))
                            } else {
                                resume(.success(()))
                            }
                        })
                    case .failed(let error):
                        resume(.failure(error))
                    case .cancelled:
                        resume(.failure(ClientError.connectionFailed))
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
