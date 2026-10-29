// Posts one command to a DEBUG Orbit's debug hook: post "<command>"
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("com.lyu.orbit.debug"), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)
