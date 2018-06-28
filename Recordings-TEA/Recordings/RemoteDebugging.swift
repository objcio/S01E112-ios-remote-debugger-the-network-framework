//
//  RemoteDebugging.swift
//  Recordings
//
//  Created by Chris Eidhof on 24.05.18.
//

import UIKit
import Network

extension UIView {
	func capture() -> UIImage? {
		let format = UIGraphicsImageRendererFormat()
		format.opaque = isOpaque
		let renderer = UIGraphicsImageRenderer(size: frame.size, format: format)
		return renderer.image { _ in
			drawHierarchy(in: frame, afterScreenUpdates: true)
		}
	}
}

struct DebugData<S: Encodable>: Encodable {
	var state: S
	var action: String
	var imageData: Data
}

func decodeJSONHeader(from data: Data) -> Int? {
	assert(data.count == 5)
	guard data.first! == 206 else { return nil }
	let count: Int32 = data.dropFirst().withUnsafeBytes { $0.pointee }
	return Int(count)
}

final class RemoteDebugger<State: Codable>: NSObject, NetServiceBrowserDelegate {
	let browser = NetServiceBrowser()
	let queue = DispatchQueue(label: "remoteDebugger")
	var connection: NWConnection?
	var onReceive: ((State) -> ())?
	let decoder = JSONDecoder()

	override init() {
		super.init()
		browser.delegate = self
		browser.searchForServices(ofType: "_debug._tcp", inDomain: "local")
	}
	
	func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
		let endpoint = NWEndpoint.service(name: service.name, type: service.type, domain: service.domain, interface: nil)
		let parameters = NWParameters.init(tls: nil, tcp: NWProtocolTCP.Options())
		connection = NWConnection(to: endpoint, using: parameters)
		connection?.start(queue: queue)
		startReading()
	}
	
	func startReading() {
		connection?.receive(minimumIncompleteLength: 5, maximumLength: 5, completion: { [unowned self] data, _, _, _ in
			guard let d = data, let bytesExpected = decodeJSONHeader(from: d) else  { print("Error"); return }
			self.connection?.receive(minimumIncompleteLength: bytesExpected, maximumLength: bytesExpected, completion: { [unowned self] data, _, _, _ in
				guard let jsonData = data, let result = try? self.decoder.decode(State.self, from: jsonData) else {
					print("Error")
					return
				}
				self.onReceive?(result)
				self.startReading()
			})
		})
	}
	
	func write(action: String, state: State, snapshot: UIView) throws {
		let image = snapshot.capture()!
		let imageData = UIImagePNGRepresentation(image)!
		let data = DebugData(state: state, action: action, imageData: imageData)
		let encoder = JSONEncoder()
		let json = try! encoder.encode(data)
		var encodedLength = Data(count: 4)
		encodedLength.withUnsafeMutableBytes { bytes in
			bytes.pointee = Int32(json.count)
		}
		connection?.send(content: [206] + encodedLength + json, completion: .idempotent)
	}
}
