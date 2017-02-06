//
//  NotificationPusher.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 2016-02-16.
//  Copyright © 2016 PerfectlySoft. All rights reserved.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

import PerfectLib
import PerfectNet
import PerfectThread
import PerfectHTTPServer
import PerfectHTTP
#if os(macOS)
	import Darwin
#else
	import SwiftGlibc
#endif

/**
Example code:

    // BEGIN one-time initialization code

    let configurationName = "My configuration name - can be whatever"

    NotificationPusher.addConfigurationIOS(configurationName) {
        (net:NetTCPSSL) in

        // This code will be called whenever a new connection to the APNS service is required.
        // Configure the SSL related settings.

        net.keyFilePassword = "if you have password protected key file"

        guard net.useCertificateFile("path/to/aps_development.pem") &&
            net.usePrivateKeyFile("path/to/aps_development.pem") &&
            net.checkPrivateKey() else {

            let code = Int32(net.errorCode())
            print("Error validating private key file: \(net.errorStr(code))")
            return
        }
    }

    NotificationPusher.development = true // set to toggle to the APNS sandbox server

    // END one-time initialization code

    // BEGIN - individual notification push

    let deviceId = "hex string device id"
    let ary = [IOSNotificationItem.alertBody("This is the message"), IOSNotificationItem.sound("default")]
    let n = NotificationPusher(apnsTopic: "com.company.my-app")

    n.pushIOS(configurationName, deviceToken: deviceId, expiration: 0, priority: 10, notificationItems: ary) {
        response in

        print("NotificationResponse: \(response.code) \(response.body)")
    }

    // END - individual notification push

*/

/// Items to configure an individual notification push.
/// These correspond to what is described here:
/// https://developer.apple.com/library/mac/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/Chapters/TheNotificationPayload.html
public enum IOSNotificationItem {
    /// alert body child property
	case alertBody(String)
    /// alert title child property
	case alertTitle(String)
    /// alert title-loc-key
	case alertTitleLoc(String, [String]?)
    /// alert action-loc-key
	case alertActionLoc(String)
    /// alert loc-key
	case alertLoc(String, [String]?)
    /// alert launch-image
	case alertLaunchImage(String)
    /// aps badge key
	case badge(Int)
    /// aps sound key
	case sound(String)
    /// aps content-available key
	case contentAvailable
    /// aps category key
	case category(String)
    /// custom payload data
	case customPayload(String, Any)
    /// apn mutable-content key
    case mutableContent
}

enum IOSItemId: UInt8 {
	case deviceToken = 1
	case payload = 2
	case notificationIdentifier = 3
	case expirationDate = 4
	case priority = 5
}

private let iosDeviceIdLength = 32
private let iosNotificationCommand = UInt8(2)
private let iosNotificationPort = UInt16(443)
private let iosNotificationDevelopmentHost = "api.development.push.apple.com"
private let iosNotificationProductionHost = "api.push.apple.com"

struct IOSNotificationError {
	let code: UInt8
	let identifier: UInt32
}

class NotificationConfiguration {
	
	let configurator: NotificationPusher.netConfigurator
	
	let keyId: String?
	let teamId: String?
	let privateKeyPath: String?
	var currentToken: String?
	var currentTokenTime = 0
	
	let lock = Threading.Lock()
	var streams = [NotificationHTTP2Client]()
	
	var usingJWT: Bool {
		return nil != keyId
	}
	
	var jwtToken: String? {
		let oneHour = 60 * 60
		let now = Int(time(nil))
		if now - currentTokenTime >= oneHour {
			guard let keyId = keyId, let teamId = teamId, let privateKeyPath = privateKeyPath else {
				return nil
			}
			currentTokenTime = now
			currentToken = makeSignature(keyId: keyId, teamId: teamId, privateKeyPath: privateKeyPath)
		}
		return currentToken
	}
	
	init(configurator: @escaping NotificationPusher.netConfigurator) {
		self.configurator = configurator
		keyId = nil
		teamId = nil
		privateKeyPath = nil
	}
	
	init(keyId: String, teamId: String, privateKeyPath: String) {
		configurator = { _ in }
		self.keyId = keyId
		self.teamId = teamId
		self.privateKeyPath = privateKeyPath
	}
}

class NotificationHTTP2Client: HTTP2Client {
	let id: Int
	
    init(id: Int) {
        self.id = id
        super.init()
	}
}

/// The response object given after a push attempt.
public struct NotificationResponse: CustomStringConvertible {
	/// The response code for the request.
	public let status: HTTPResponseStatus
	/// The response body data bytes.
	public let body: [UInt8]
	/// The body data bytes interpreted as JSON and decoded into a Dictionary.
	public var jsonObjectBody: [String:Any] {
		do {
			if let json = try self.stringBody.jsonDecode() as? [String:Any] {
				return json
			}
		}
		catch {}
		return [String:Any]()
	}
	/// The body data bytes converted to String.
	public var stringBody: String {
		return UTF8Encoding.encode(bytes: self.body)
	}
	
	public var description: String {
		return "\(status): \(stringBody)"
	}
}

/// The interface for APNS notifications.
public class NotificationPusher {
	
	typealias ComponentGenerator = IndexingIterator<[String]>
	
	/// On-demand configuration for SSL related functions.
	public typealias netConfigurator = (NetTCPSSL) -> ()
	
	/// Toggle development or production on a global basis.
	public static var development = false

	/// Sets the apns-topic which will be used for iOS notifications.
	public var apnsTopic: String?

	var responses = [NotificationResponse]()
	
	static var idCounter = 0
	
	static var notificationHostIOS: String {
		if self.development {
			return iosNotificationDevelopmentHost
		}
		return iosNotificationProductionHost
	}
	
	static let configurationsLock = Threading.Lock()
	static var iosConfigurations = [String:NotificationConfiguration]()
	static var activeStreams = [Int:NotificationHTTP2Client]()
	
	public static func addConfigurationIOS(name: String, configurator: @escaping netConfigurator = { _ in }) {
		self.configurationsLock.doWithLock {
			self.iosConfigurations[name] = NotificationConfiguration(configurator: configurator)
		}
	}
	
	public static func addConfigurationIOS(name: String, certificatePath: String) {
		addConfigurationIOS(name: name) {
			net in

			guard File(certificatePath).exists else {
				fatalError("File not found \(certificatePath)")
			}
			guard net.useCertificateFile(cert: certificatePath)
				&& net.usePrivateKeyFile(cert: certificatePath)
				&& net.checkPrivateKey()
				  else {
					let code = Int32(net.errorCode())
					print("Error validating private key file: \(net.errorStr(forCode: code))")
					return
			}
		}
	}
	
	public static func addConfigurationIOS(name: String, keyId: String, teamId: String, privateKeyPath: String) {
		self.configurationsLock.doWithLock {
			self.iosConfigurations[name] = NotificationConfiguration(keyId: keyId, teamId: teamId, privateKeyPath: privateKeyPath)
		}
	}
	
	static func getStreamIOS(configurationName configuration: String, callback: @escaping (HTTP2Client?, NotificationConfiguration?) -> ()) {
		var conf: NotificationConfiguration?
		self.configurationsLock.doWithLock {
			conf = self.iosConfigurations[configuration]
		}
        guard let c = conf else {
            return callback(nil, nil)
        }
        var net: NotificationHTTP2Client?
        var needsConnect = false
        c.lock.doWithLock {
            if c.streams.count > 0 {
                net = c.streams.removeLast()
            } else {
                needsConnect = true
                net = NotificationHTTP2Client(id: idCounter)
                activeStreams[idCounter] = net
                idCounter = idCounter &+ 1
            }
        }
        guard needsConnect else {
            callback(net, c)
            return
        }
		
		net?.net.initializedCallback = c.configurator
        net?.connect(host: self.notificationHostIOS, port: iosNotificationPort, ssl: true, timeoutSeconds: 5.0) {
            b in
            if b {
                callback(net!, c)
            } else {
                callback(nil, nil)
            }
        }
	}
	
	static func releaseStreamIOS(configurationName configuration: String, net: HTTP2Client) {
		var conf: NotificationConfiguration?
		self.configurationsLock.doWithLock {
			conf = self.iosConfigurations[configuration]
		}
		
        guard let c = conf, let n = net as? NotificationHTTP2Client  else {
            net.close()
            return
        }
        
        c.lock.doWithLock {
            activeStreams.removeValue(forKey: n.id)
            if net.isConnected {
                c.streams.append(n)
            }
        }
	}
	
    /// Public initializer
	public init() {

	}

	/// Initialize given iOS apns-topic string.
	/// This can be set after initialization on the X.apnsTopic property.
	public init(apnsTopic: String) {
		self.apnsTopic = apnsTopic
	}

	func resetResponses() {
		self.responses.removeAll()
	}
	
	/// Push one message to one device.
	/// Provide the previously set configuration name, device token.
	/// Provide the expiration and priority as described here:
	///		https://developer.apple.com/library/mac/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/Chapters/APNsProviderAPI.html
	/// Provide a list of IOSNotificationItems.
	/// Provide a callback with which to receive the response.
	public func pushIOS(configurationName: String, deviceToken: String, expiration: UInt32, priority: UInt8, notificationItems: [IOSNotificationItem], callback: @escaping (NotificationResponse) -> ()) {
		pushIOS(configurationName: configurationName, deviceTokens: [deviceToken], expiration: expiration, priority: priority, notificationItems: notificationItems, callback: { lst in callback(lst.first!) })
	}
	
	/// Push one message to multiple devices.
	/// Provide the previously set configuration name, and zero or more device tokens. The same message will be sent to each device.
	/// Provide the expiration and priority as described here:
	///		https://developer.apple.com/library/mac/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/Chapters/APNsProviderAPI.html
	/// Provide a list of IOSNotificationItems.
	/// Provide a callback with which to receive the responses.
	public func pushIOS(configurationName: String, deviceTokens: [String], expiration: UInt32, priority: UInt8, notificationItems: [IOSNotificationItem], callback: @escaping ([NotificationResponse]) -> ()) {
		
		NotificationPusher.getStreamIOS(configurationName: configurationName) {
			client, config in
            guard let c = client, let config = config else {
                callback([NotificationResponse(status: .internalServerError, body: [UInt8]())])
                return
            }
			self.pushIOS(c, config: config, deviceTokens: deviceTokens, expiration: expiration, priority: priority, notificationItems: notificationItems) {
                responses in
                
                NotificationPusher.releaseStreamIOS(configurationName: configurationName, net: c)
                
                guard responses.count == deviceTokens.count else {
                    callback([NotificationResponse(status: .internalServerError, body: [UInt8]())])
                    return
                }
                callback(responses)
            }
		}
	}
	
	func pushIOS(_ net: HTTP2Client, config: NotificationConfiguration, deviceToken: String, expiration: UInt32, priority: UInt8, notificationJson: [UInt8], callback: @escaping (NotificationResponse) -> ()) {
		
		let request = net.createRequest()
		request.method = .post
		request.postBodyBytes = notificationJson
        request.setHeader(.contentType, value: "application/json; charset=utf-8")
        request.setHeader(.custom(name: "apns-expiration"), value: "\(expiration)")
        request.setHeader(.custom(name: "apns-priority"), value: "\(priority)")
		
		if let apnsTopic = apnsTopic {
            request.setHeader(.custom(name: "apns-topic"), value: apnsTopic)
		}
		
		if config.usingJWT, let token = config.jwtToken {
			request.setHeader(.authorization, value: "bearer \(token)")
		}
		
		request.path = "/3/device/\(deviceToken)"
		net.sendRequest(request) {
			response, msg in
			
            guard let r = response else {
                callback(NotificationResponse(status: .internalServerError, body: UTF8Encoding.decode(string: "No response")))
                return
            }
            callback(NotificationResponse(status: r.status, body: r.bodyBytes))
		}
	}
	
	func pushIOS(_ client: HTTP2Client, config: NotificationConfiguration, deviceTokens: ComponentGenerator, expiration: UInt32, priority: UInt8, notificationJson: [UInt8], callback: @escaping ([NotificationResponse]) -> ()) {
		var g = deviceTokens
        guard let next = g.next() else {
            callback(self.responses)
            return
        }
		pushIOS(client, config: config, deviceToken: next, expiration: expiration, priority: priority, notificationJson: notificationJson) {
            response in
            
            self.responses.append(response)
            
			self.pushIOS(client, config: config, deviceTokens: g, expiration: expiration, priority: priority, notificationJson: notificationJson, callback: callback)
        }
	}
	
	func pushIOS(_ client: HTTP2Client, config: NotificationConfiguration, deviceTokens: [String], expiration: UInt32, priority: UInt8, notificationItems: [IOSNotificationItem], callback: @escaping ([NotificationResponse]) -> ()) {
		self.resetResponses()
		let g = deviceTokens.makeIterator()
		let jsond = UTF8Encoding.decode(string: self.itemsToPayloadString(notificationItems: notificationItems))
		self.pushIOS(client, config: config, deviceTokens: g, expiration: expiration, priority: priority, notificationJson: jsond, callback: callback)
	}
	
	func itemsToPayloadString(notificationItems items: [IOSNotificationItem]) -> String {
		var dict = [String:Any]()
		var aps = [String:Any]()
		var alert = [String:Any]()
		var alertBody: String?
		
		for item in items {
			switch item {
			case .alertBody(let s):
				alertBody = s
			case .alertTitle(let s):
				alert["title"] = s
			case .alertTitleLoc(let s, let a):
				alert["title-loc-key"] = s
				if let titleLocArgs = a {
					alert["title-loc-args"] = titleLocArgs
				}
			case .alertActionLoc(let s):
				alert["action-loc-key"] = s
			case .alertLoc(let s, let a):
				alert["loc-key"] = s
				if let locArgs = a {
					alert["loc-args"] = locArgs
				}
			case .alertLaunchImage(let s):
				alert["launch-image"] = s
			case .badge(let i):
				aps["badge"] = i
			case .sound(let s):
				aps["sound"] = s
			case .contentAvailable:
				aps["content-available"] = 1
			case .category(let s):
				aps["category"] = s
			case .customPayload(let s, let a):
				dict[s] = a
            case .mutableContent:
                aps["mutable-content"] = 1
            }
		}
		
		if let ab = alertBody {
			if alert.count == 0 { // just a string alert
				aps["alert"] = ab
			} else { // a dict alert
				alert["body"] = ab
				aps["alert"] = alert
			}
		}
		
		dict["aps"] = aps
		do {
			return try dict.jsonEncodedString()
		}
		catch {}
		return "{}"
	}
}

// !FIX! Downcasting to protocol does not work on Linux
// Not sure if this is intentional, or a bug.
func jsonEncodedStringWorkAround(_ o: Any) throws -> String {
    switch o {
    case let jsonAble as JSONConvertibleObject: // as part of Linux work around
        return try jsonAble.jsonEncodedString()
    case let jsonAble as JSONConvertible:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as String:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as Int:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as UInt:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as Double:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as Bool:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as [Any]:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as [[String:Any]]:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as [String:Any]:
        return try jsonAble.jsonEncodedString()
    default:
        throw JSONConversionError.notConvertible(o)
    }
}

private func jsonSerialize(o: Any) -> String? {
	do {
		return try jsonEncodedStringWorkAround(o)
	} catch let e as JSONConversionError {
		print("Could not convert to JSON: \(e)")
	} catch {}
	return nil
}
