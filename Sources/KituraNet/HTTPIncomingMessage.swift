/**
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/


import KituraSys
import Socket

import Foundation

// MARK: IncomingMessage

public class HTTPIncomingMessage : HTTPParserDelegate, SocketReader {

    /// Default buffer size used for creating a BufferList
    private static let bufferSize = 2000

    /// Major version for HTTP
    public private(set) var httpVersionMajor: UInt16?

    /// Minor version for HTTP
    public private(set) var httpVersionMinor: UInt16?

    /// Set of headers
    public var headers = HeadersContainer()

    /// HTTP Method
    public private(set) var method: String = "" // TODO: enum?

    /// URL
    public private(set) var urlString = ""

    /// Raw URL
    public private(set) var url = NSMutableData()

    // MARK: - Private
    
    // TODO: trailers

    /// State of callbacks from parser WRT headers
    private var lastHeaderWasAValue = false

    /// Bytes of a header key that was just parsed and returned in chunks by the pars
    private var lastHeaderField = NSMutableData()

    /// Bytes of a header value that was just parsed and returned in chunks by the parser
    private var lastHeaderValue = NSMutableData()

    /// The http_parser Swift wrapper
    private var httpParser: HTTPParser?

    /// State of incoming message handling
    private var status = HTTPParserStatus()

    /// Chunk of body read in by the http_parser, filled by callbacks to onBody
    private var bodyChunk = BufferList()

    /// Reader helper, reads from underlying data source
    private weak var helper: IncomingMessageHelper?

    /// TODO:
    private var ioBuffer = NSMutableData(capacity: HTTPIncomingMessage.bufferSize)
    
    /// TODO: ???
    private var buffer = NSMutableData(capacity: HTTPIncomingMessage.bufferSize)

    /// Indicates if the parser should save the message body and call onBody()
    var saveBody = true
    
    

    /// Initializes a new IncomingMessage
    ///
    /// - Parameter isRequest: whether this message is a request
    ///
    /// - Returns: an IncomingMessage instance
    init (isRequest: Bool) {
        httpParser = HTTPParser(isRequest: isRequest)

        httpParser!.delegate = self
    }

    /// Sets a helper delegate
    ///
    /// - Parameter helper: the IncomingMessageHelper
    func setup(_ helper: IncomingMessageHelper) {
        self.helper = helper
    }
    
    /// Parse the message
    ///
    /// - Parameter callback: (HTTPParserStatus) -> Void closure
    func parse (_ buffer: NSData) -> HTTPParserStatus {
        guard let parser = httpParser else {
            status.error = .internalError
            return status
        }
        
        var length = buffer.length
        
        guard length > 0  else {
            /* Handle unexpected EOF. Usually just close the connection. */
            freeHTTPParser()
            status.error = .unexpectedEOF
            return status
        }
        
        // If we were reset because of keep alive
        if  status.state == .reset  {
            status.reset()
            parser.reset()
        }
        
        var start = 0
        while status.state == .initial  &&  length > 0  {
            
            let (numberParsed, upgrade) = parser.execute(UnsafePointer<Int8>(buffer.bytes)+start, length: length)
            if upgrade == 1 {
                // TODO handle new protocol
            }
            else if  numberParsed != length  {
                
                if  status.state == .reset  {
                    // Apparently the short message was a Continue. Let's just keep on parsing
                    status.state = .initial
                    start = numberParsed
                    parser.reset()
                }
                else {
                    /* Handle error. Usually just close the connection. */
                    freeHTTPParser()
                    status.error = .parsedLessThanRead
                }
            }
            length -= numberParsed
        }
        
        return status
    }

    /// Read data in the message
    ///
    /// - Parameter data: An NSMutableData to hold the data in the message
    ///
    /// - Returns: the number of bytes read
    public func read(into data: NSMutableData) throws -> Int {
        var count = bodyChunk.fill(data: data)
        if count == 0 {
            if let parser = httpParser where status.state == .headersComplete {
                do {
                    ioBuffer!.length = 0
                    count = try helper!.readHelper(into: ioBuffer!)
                    if count > 0 {
                        let (numberParsed, upgrade) = parser.execute(UnsafePointer<Int8>(ioBuffer!.bytes), length: count)
                        if upgrade == 1 {
                            // TODO: handle new protocol
                        }
                        else if (numberParsed != count) {
                            /* Handle error. Usually just close the connection. */
                            freeHTTPParser()
                            status.error = .parsedLessThanRead
                        }
                        else {
                            count = bodyChunk.fill(data: data)
                        }
                    }
                    else {
                        onMessageComplete()
                    }
                }
                catch let error {
                    /* Handle error. Usually just close the connection. */
                    freeHTTPParser()
                    status.error = .internalError
                    throw error
                }
            }
        }

        return count
    }

    /// Read all data in the message
    ///
    /// - Parameter data: An NSMutableData to hold the data in the message
    ///
    /// - Returns: the number of bytes read
    @discardableResult
    public func readAllData(into data: NSMutableData) throws -> Int {
        var length = try read(into: data)
        var bytesRead = length
        while length > 0 {
            length = try read(into: data)
            bytesRead += length
        }
        return bytesRead
    }

    /// Read message body without storing it anywhere
    func drain() {
        if let parser = httpParser {
            saveBody = false
            while status.state == .headersComplete {
                do {
                    ioBuffer!.length = 0
                    let count = try helper!.readHelper(into: ioBuffer!)
                    if count > 0 {
                        let (numberParsed, _) = parser.execute(UnsafePointer<Int8>(ioBuffer!.bytes), length: count)
                        if (numberParsed != count) {
                            freeHTTPParser()
                            status.error = .parsedLessThanRead
                        }
                    }
                    else {
                        onMessageComplete()
                    }
                }
                catch {
                    freeHTTPParser()
                    status.error = .internalError
                }
            }
        }
    }

    /// Read the string
    ///
    /// - Throws: TODO ???
    /// - Returns: an Optional string
    public func readString() throws -> String? {

        buffer!.length = 0
        let length = try read(into: buffer!)
        if length > 0 {
            return StringUtils.fromUtf8String(buffer!)
        }
        else {
            return nil
        }
        
    }

    /// Free the httpParser from the IncomingMessage
    private func freeHTTPParser () {
        
        httpParser?.delegate = nil
        httpParser = nil
        
    }

    /// Instructions for when reading URL portion
    ///
    /// - Parameter data: the data
    func onURL(_ data: NSData) {
        #if os(Linux)
            url.append(data)
        #else
            url.append(data as Data)
        #endif
    }

    /// Instructions for when reading header field
    ///
    /// - Parameter data: the data
    func onHeaderField (_ data: NSData) {
        
        if lastHeaderWasAValue {
            addHeader()
        }
        #if os(Linux)
            lastHeaderField.append(data)
        #else
            lastHeaderField.append(data as Data)
        #endif

        lastHeaderWasAValue = false
        
    }

    /// Instructions for when reading a header value
    ///
    /// - Parameter data: the data
    func onHeaderValue (_ data: NSData) {
        #if os(Linux)
            lastHeaderValue.append(data)
        #else
            lastHeaderValue.append(data as Data)
        #endif

        lastHeaderWasAValue = true
    }

    /// Set the header key-value pair
    private func addHeader() {

        let headerKey = StringUtils.fromUtf8String(lastHeaderField)!
        let headerValue = StringUtils.fromUtf8String(lastHeaderValue)!
        
        switch(headerKey.lowercased()) {
            // Headers with a simple value that are not merged (i.e. duplicates dropped)
            // https://mxr.mozilla.org/mozilla/source/netwerk/protocol/http/src/nsHttpHeaderArray.cpp
            //
            case "content-type", "content-length", "user-agent", "referer", "host",
                 "authorization", "proxy-authorization", "if-modified-since",
                 "if-unmodified-since", "from", "location", "max-forwards",
                 "retry-after", "etag", "last-modified", "server", "age", "expires":
                if let _ = headers[headerKey] {
                    break
                }
                fallthrough
            default:
                headers.append(headerKey, value: headerValue)
        }

        lastHeaderField.length = 0
        lastHeaderValue.length = 0

    }

    /// Instructions for when reading the body of the message
    ///
    /// - Parameter data: the data
    func onBody (_ data: NSData) {
        self.bodyChunk.append(data: data)

    }

    /// Instructions for when the headers have been finished being parsed.
    ///
    /// - Parameter method: the HTTP method
    /// - Parameter versionMajor: major version of HTTP
    /// - Parameter versionMinor: minor version of HTTP
    func onHeadersComplete(method: String, versionMajor: UInt16, versionMinor: UInt16) {
        
        httpVersionMajor = versionMajor
        httpVersionMinor = versionMinor
        self.method = method
        urlString = StringUtils.fromUtf8String(url) ?? ""

        if  lastHeaderWasAValue  {
            addHeader()
        }

        status.keepAlive = httpParser?.isKeepAlive() ?? false
        status.state = .headersComplete
        
    }

    /// Instructions for when beginning to read a message
    func onMessageBegin() {
    }

    /// Instructions for when done reading the message
    func onMessageComplete() {
        
        status.keepAlive = httpParser?.isKeepAlive() ?? false
        status.state = .messageComplete
        if  !status.keepAlive  {
            freeHTTPParser()
        }
    }

    /// instructions for when reading is reset
    func reset() {
        lastHeaderWasAValue = false
        url.length = 0
        status.state = .reset
    }

}


/// Protocol for IncomingMessageHelper
protocol IncomingMessageHelper: class {

    /// "Read" data from the actual underlying transport
    ///
    /// - Parameter into: The NSMutableData that will be receiving the data read in.
    func readHelper(into data: NSMutableData) throws -> Int

}
