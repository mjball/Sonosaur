import Foundation

/// Thin wrapper around URLSession for Sonos UPnP/SOAP calls on port 1400.
enum SoapClient {

    enum SoapError: Error {
        case badURL
        case httpError(Int)
        case missingTag(String)
        case parseError(String)
    }

    // MARK: - Public API

    /// Fire a SOAP action and return the raw response body as a String.
    static func post(
        host: String,
        path: String,
        service: String,
        action: String,
        bodyXML: String
    ) async throws -> String {
        guard let url = URL(string: "http://\(host):1400\(path)") else {
            throw SoapError.badURL
        }

        let envelope = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(service)">\(bodyXML)</u:\(action)>
          </s:Body>
        </s:Envelope>
        """

        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = envelope.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SoapError.httpError(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Pull the first text content of a named XML tag from a SOAP response.
    static func extractTag(_ tag: String, from xml: String) throws -> String {
        let pattern = "<\(tag)>([^<]*)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml)
        else {
            throw SoapError.missingTag(tag)
        }
        return String(xml[range])
    }
}
