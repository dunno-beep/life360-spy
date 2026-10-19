import Foundation

enum Config {
    static let appGroup = "group.com.you.life360"
    static let token = "my-long-secret"
    static let brokerHost = "broker.emqx.io"
    static let brokerPort = 8084
    static let brokerPath = "/mqtt"
    static let upTopic = "l360/\(token)/up"
    static let downTopic = "l360/\(token)/down"
    static let binTopic = "l360/\(token)/bin"
    static let relayHost = brokerHost
    static let relayPort = brokerPort
}
