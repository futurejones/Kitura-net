/*
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
 */
/**
    The protocol defining the delegate for the HTTPServer and the FastCGIServer classes.
    The delegate's handle function is invoked when new requests arrive at the server for processing.


 ### Usage Example: ###
 ````swift
 func handle(request: ServerRequest, response: ServerResponse) {
 
     let parsedURL = URLParser(url: request.url, isConnect: false)
 
     if parsedURL.path == "/hello" {
        let payload = "Hello, world!"
        response.headers["Content-Type"] = ["text/plain"]
        response.headers["Content-Length"] = [String(payload.characters.count)]
        response.statusCode = .OK
        do {
            try response.write(from: payload)
            try response.end()
        }
        catch {
            print("Failed to write the response. Error: \(error)")
        }
 }
 ````
 */

public protocol ServerDelegate: class {
    
    /**
     Handle new incoming requests to the server
     
     ### Usage Example: ###
     ````swift
     self.delegate.handle(request: request, response: response)
     ````
    
     - Parameter request: The ServerRequest class instance for working with this request.
                         The ServerRequest object enables you to get the query parameters, headers, and body amongst other
                         information about the incoming request.
     - Parameter response: The ServerResponse class instance for working with this request.
                         The ServerResponse object enables you to build and send your response to the client who sent
                         the request. This includes headers, the body, and the response code.
 */
    func handle(request: ServerRequest, response: ServerResponse)
}
