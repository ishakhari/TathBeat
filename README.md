<p align="center">
  <img src="assets/icon/lockup.png" alt="TathBeat" width="420">
</p>

<p align="center">
  Loop any part of a YouTube video. Pick a start and an end, press play, and TathBeat repeats just that section.
</p>

---

## What it does

Paste a YouTube link, choose where the loop starts and ends, and TathBeat plays that section over and over. It's handy for practicing music, learning a phrase in a language, studying a lecture segment, or replaying a favorite moment.

## Features

- **Any YouTube link:** `youtu.be`, `youtube.com/watch`, `m.youtube.com`, Shorts, embed links, or a bare video ID
- **Range slider:** drag the start and end handles on the video's timeline
- **Exact times:** type the start and end as `m:ss` or `h:mm:ss`, or plain seconds
- **"= Now" buttons:** set the start or end from the current playback position
- **Looping:** play repeats between your start and end; turn looping off with the repeat button
- **Playback speed:** 0.75x, 1x, 1.25x, 1.5x and 2x
- **Quick controls:** jump back to the loop start, clear or paste the link in one tap

## Screenshots

<!-- Add screenshots to a docs/ folder and link them here, e.g.
<p>
  <img src="docs/screenshot-1.png" width="260">
  <img src="docs/screenshot-2.png" width="260">
</p>
-->

## Getting started

### Requirements

- [Flutter](https://docs.flutter.dev/get-started/install) (a recent stable version)
- An Android device or emulator (64-bit image, API 21 or higher)

### Run it

```bash
git clone https://github.com/ishakhari/TathBeat.git
cd TathBeat
flutter pub get
flutter run -d <device_id>
```

Find your device id with `flutter devices`.

### Generate the launcher icons (optional)

The icon files are already in `assets/icon/`. To regenerate the Android launcher icons:

```bash
dart run flutter_launcher_icons
```

## How to use

1. Paste a YouTube link and tap **Go**.
2. Wait a moment for the video length to load.
3. Drag the two handles on the slider, or type the **Début** and **Fin** times.
4. Press **play**. The video repeats between your two points.
5. Change the speed with the chips at the bottom.

## Tech stack

- [Flutter](https://flutter.dev) and Dart
- [`youtube_player_iframe`](https://pub.dev/packages/youtube_player_iframe) for the embedded YouTube player
- Material 3 with a dark theme

## Project structure

```
lib/main.dart         App code (UI, player logic, loop logic)
assets/icon/          Logo and launcher icon sources
android/              Android project files
pubspec.yaml          Dependencies and assets
```

## Known limitations

- **Android only:** the YouTube player package doesn't support desktop or web builds.
- **No background playback:** audio pauses when the app goes to the background or the screen locks. YouTube's embedded player is designed to work this way.
- **Needs internet:** videos stream from YouTube and can't be used offline.
- **Loop timing:** the loop point is checked a few times per second, so the jump back can be off by a fraction of a second.

## Disclaimer

TathBeat is an independent project and isn't affiliated with or endorsed by YouTube or Google. Videos play through YouTube's official embedded player, and their content belongs to their owners.

## License

Choose a license for your project (for example [MIT](https://choosealicense.com/licenses/mit/)) and add a `LICENSE` file, then replace this line with its name.
