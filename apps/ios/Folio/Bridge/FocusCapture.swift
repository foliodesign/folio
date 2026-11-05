import Foundation

struct FocusCapture: Codable, Equatable {
  let event: String
  let tag: String
  let inputType: String
  let innerWidth: Double
  let innerHeight: Double
  let width: Double
  let height: Double
  let offsetLeft: Double
  let offsetTop: Double
  let scale: Double
  let scrollX: Double
  let scrollY: Double
  let time: Double
}
