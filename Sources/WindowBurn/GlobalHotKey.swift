import Carbon.HIToolbox
import Foundation

final class GlobalHotKey: @unchecked Sendable {
  enum RegistrationError: LocalizedError {
    case handler(OSStatus)
    case hotKey(String, OSStatus)

    var errorDescription: String? {
      switch self {
      case .handler(let status):
        "Could not install the hotkey handler (OSStatus \(status))."
      case .hotKey(let shortcut, let status):
        "Could not register \(shortcut) (OSStatus \(status))."
      }
    }
  }

  private static let signature: OSType = 0x5742_524E  // "WBRN"
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?
  private let identifierID: UInt32
  private let action: @MainActor () -> Void

  init(
    keyCode: UInt32,
    identifierID: UInt32,
    shortcut: String,
    action: @escaping @MainActor () -> Void
  ) throws {
    self.identifierID = identifierID
    self.action = action

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let handlerStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var identifier = EventHotKeyID()
        let status = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &identifier
        )
        guard status == noErr, identifier.signature == GlobalHotKey.signature else {
          return OSStatus(eventNotHandledErr)
        }

        let instance = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        guard identifier.id == instance.identifierID else {
          return OSStatus(eventNotHandledErr)
        }
        MainActor.assumeIsolated {
          instance.action()
        }
        return noErr
      },
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandlerRef
    )
    guard handlerStatus == noErr else {
      throw RegistrationError.handler(handlerStatus)
    }

    let identifier = EventHotKeyID(signature: Self.signature, id: identifierID)
    let modifiers = UInt32(cmdKey | optionKey | controlKey)
    let registrationStatus = RegisterEventHotKey(
      keyCode,
      modifiers,
      identifier,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
    guard registrationStatus == noErr else {
      if let eventHandlerRef {
        RemoveEventHandler(eventHandlerRef)
      }
      throw RegistrationError.hotKey(shortcut, registrationStatus)
    }
  }

  deinit {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
    }
  }
}
