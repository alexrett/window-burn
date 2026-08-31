# Privacy

Window Burn does not collect, retain, or transmit personal data. It has no analytics, telemetry,
network client, account system, or cloud service.

The app needs powerful macOS permissions because of how the effect works:

- **Screen Recording** captures the selected window into memory immediately before the animation.
- **Accessibility** finds and closes windows and activates the destructive action in a recognized
  unsaved-document confirmation.
- **Input Monitoring** observes close-button clicks and interactive torch gestures.

Captured window images exist only in process memory for the duration of an effect. Window Burn
does not write them to disk or send them anywhere.

Because Window Burn intentionally chooses **Delete / Don't Save** in recognized close-confirmation
dialogs, unsaved document changes can be permanently lost. This is product behavior, not data
collection.
