import Foundation

/// Every motion parameter that can drive a MIDI mapping in Phase 1.
/// Phase 2 adds gesture sources (shake, flick, throw, catch, etc.)
/// on top of this enum without changing the mapping pipeline.
enum MotionSource: String, Codable, CaseIterable, Identifiable {
    case pitch, roll, yaw
    case gravityX, gravityY, gravityZ
    case rotationX, rotationY, rotationZ
    case accelX, accelY, accelZ
    case magnitude

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pitch:     return "Pitch (tilt fwd/back)"
        case .roll:      return "Roll (tilt left/right)"
        case .yaw:       return "Yaw (compass twist)"
        case .gravityX:  return "Gravity X"
        case .gravityY:  return "Gravity Y"
        case .gravityZ:  return "Gravity Z"
        case .rotationX: return "Rotation Rate X"
        case .rotationY: return "Rotation Rate Y"
        case .rotationZ: return "Rotation Rate Z"
        case .accelX:    return "Acceleration X"
        case .accelY:    return "Acceleration Y"
        case .accelZ:    return "Acceleration Z"
        case .magnitude: return "Motion Magnitude"
        }
    }

    var shortLabel: String {
        switch self {
        case .pitch: return "PITCH"
        case .roll:  return "ROLL"
        case .yaw:   return "YAW"
        case .gravityX: return "GRV X"
        case .gravityY: return "GRV Y"
        case .gravityZ: return "GRV Z"
        case .rotationX: return "ROT X"
        case .rotationY: return "ROT Y"
        case .rotationZ: return "ROT Z"
        case .accelX: return "ACC X"
        case .accelY: return "ACC Y"
        case .accelZ: return "ACC Z"
        case .magnitude: return "MAG"
        }
    }
}
