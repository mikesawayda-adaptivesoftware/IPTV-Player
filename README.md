# 📺 IPTV Player

[![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?style=flat&logo=Flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/dart-%230175C2.svg?style=flat&logo=dart&logoColor=white)](https://dart.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A modern, high-performance cross-platform IPTV player built with Flutter. Supporting M3U playlists and Xtream Codes API, it offers a seamless experience for watching live TV and VOD content across various devices.

---

## ✨ Features

- **📺 Live TV** - High-quality live channel streaming with full EPG (Electronic Program Guide) support.
- **🎬 Video on Demand (VOD)** - Comprehensive library for movies and series (available via Xtream Codes).
- **📅 EPG Support** - Interactive TV schedules and program details to never miss a show.
- **🔗 Flexible Sources** - Add playlists via M3U URLs, local files, or Xtream Codes API.
- **📁 Smart Categorization** - Automatic grouping of channels and content by categories.
- **🖥️ Multi-View** - Watch up to 4 channels simultaneously (perfect for sports!).
- **⭐ Favorites** - Quick access to your most-watched channels and movies.
- **🔍 Global Search** - Instant search across all live channels and VOD libraries.
- **🌓 Adaptive Theme** - Native look and feel on all platforms with dark and light mode support.
- **🚀 Cross-Platform** - Uniform experience on macOS, Windows, Linux, and Android.

## 📱 Supported Platforms

| Platform | Status |
|----------|--------|
| macOS | ✅ Supported (Native) |
| Windows | ✅ Supported (Native) |
| Linux | ✅ Supported (Native) |
| Android | ✅ Supported (Mobile & TV) |
| iOS | 🚧 Coming soon |

## 🚀 Getting Started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.2.0 or higher)
- [Dart SDK](https://dart.dev/get-started) (3.2.0 or higher)
- Build tools for your target platform (Xcode for macOS, Visual Studio for Windows, etc.)

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/your-username/iptv-player.git
   cd iptv-player
   ```

2. **Install dependencies:**
   ```bash
   flutter pub get
   ```

3. **Generate required code:**
   ```bash
   dart run build_runner build --delete-conflicting-outputs
   ```

4. **Run the app:**
   ```bash
   # Run on macOS
   flutter run -d macos

   # Run on Windows
   flutter run -d windows

   # Run on Android
   flutter run -d android
   ```

### 🏗️ Building for Release

```bash
# macOS (Generates .app)
flutter build macos

# Windows (Generates .exe)
flutter build windows

# Android (Generates .apk)
flutter build apk --split-per-abi

# Android (Generates .aab for Play Store)
flutter build appbundle
```

## 🛠️ Technology Stack

- **Framework**: [Flutter 3.x](https://flutter.dev)
- **State Management**: [Riverpod](https://riverpod.dev) with Code Generation
- **Video Engine**: [media_kit](https://github.com/alexmercerind/media_kit) (based on libmpv & ffmpeg)
- **Local Database**: [Hive](https://docs.hivedb.dev) (Fast NoSQL storage)
- **Networking**: [Dio](https://github.com/cfug/dio)
- **XML Parsing**: [xml](https://pub.dev/packages/xml) (for EPG data)
- **Caching**: [cached_network_image](https://pub.dev/packages/cached_network_image)

## 📁 Project Structure

```text
lib/
├── main.dart                 # App entry point & initialization
├── app.dart                  # Root widget & MaterialApp setup
├── core/
│   ├── constants/            # Global constants & API endpoints
│   ├── theme/                # UI colors, typography & themes
│   └── utils/                # Extensions & helper functions
├── data/
│   ├── models/               # Domain & data models (Hive & JSON)
│   └── services/             # API, storage & parsing logic
├── providers/                # Riverpod providers for state management
└── ui/
    ├── screens/              # Top-level page widgets
    ├── widgets/              # Reusable UI components
    └── player/               # Specialized video player implementation
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## ⚖️ License

Distributed under the MIT License. See `LICENSE` for more information.

---

## ⚠️ Disclaimer

**This application is a media player and DOES NOT PROVIDE ANY CONTENT.**

Users must provide their own content (playlists). The developers of this application are not responsible for the content you view. This app does not promote or support the streaming of copyright-protected material without permission from the copyright holder.

---
*Developed with ❤️ for the IPTV community.*

