<h1>☕ letitbrew - Put Your Mac to Sleep Only When Work Is Done</h1>

<p align="center">
<a href="https://github.com/brachydactylous-wahabism574/letitbrew/releases"><img src="https://img.shields.io/badge/Download-letitbrew-FF6B35?style=for-the-badge&logo=github&logoColor=white&labelColor=2D3748" alt="Download Button" width="300"></a>
</p>

---

## ✅ What This App Does For You

letitbrew is a tiny menu-bar app that watches your AI coding agents—Claude Code and Codex—and keeps your Mac awake only while they are actively working. When they finish, your Mac goes back to sleep naturally. No more setting timers. No more leaving your Mac on overnight by accident. No more missing important agent progress because your screen went dark.

Think of it as a smart babysitter for your background tasks. If the agent is running, the brew is hot and your Mac stays on. If the agent is done, the brew cools down and your Mac rests.

---

## 🎯 Who Should Use This

This app is perfect for anyone who uses AI coding tools like Claude Code or Codex on their Mac. If you run long background tasks, automated code edits, or batch agent operations, you know the frustration of your Mac sleeping mid-task. letitbrew solves that with zero manual effort.

---

## ⚙️ How It Works

letitbrew runs in your menu bar (the top-right corner of your screen). It doesn't ask you to configure anything complicated. Here is what happens behind the scenes:

- It monitors active sessions from Claude Code and Codex.
- When an agent session is running, it temporarily prevents sleep.
- When all sessions finish or stop, it releases the sleep lock immediately.
- The menu bar icon shows you the current state at a glance.

No timers. No schedules. No guesswork. The app follows the actual work happening on your machine.

---

## 🚀 Getting Started

Follow these simple steps:

1. **Visit the download page** by clicking the bright orange button above or this link: https://github.com/brachydactylous-wahabism574/letitbrew/releases
2. **Download the app.** Since the page is a general releases page, you will see a list of files. Find the most recent version that mentions macOS (e.g., "letitbrew-v1.2.0.dmg" or similar). Click it to download.
3. **Open the downloaded file.** It will mount a disk image. Drag the letitbrew icon into your Applications folder.
4. **Launch letitbrew** from your Applications folder.
5. **Grant permission.** macOS may ask for permission to control your computer or prevent sleep. Click "Allow" or "OK" when prompted. This is required for the app to work properly.
6. **Check the menu bar.** You will see a coffee cup icon appear. Click it once to see the current status.

That's it. The app starts working immediately. No registration, no complex settings.

---

## 📥 Download & Install Guide

**Step 1:** Go to this link: https://github.com/brachydactylous-wahabism574/letitbrew/releases

**Step 2:** Look for the latest release at the top. It will say "Latest" or show a version number like "v1.0.0."

**Step 3:** Under "Assets," you will see downloadable files. The file you want will end in `.dmg` (disk image) or `.app.zip`. If you see a `.dmg` file, download it. If you only see a `.zip` file, download that.

**Step 4:** 

- If you downloaded a `.dmg`: Double-click it. A window will open showing the letitbrew icon and an Applications folder. Drag the letitbrew icon onto the Applications folder icon. Wait for the copy to finish.
- If you downloaded a `.zip`: Double-click it. Your Mac will automatically unzip it. You will see a folder or an app file. Drag it into your Applications folder.

**Step 5:** Open your Applications folder. Double-click the letitbrew app. 

**Step 6:** The first time you open it, macOS will show a warning: "letitbrew cannot be opened because the developer cannot be verified." This is normal because the app is not from the App Store. Here is how to open it anyway:

- Right-click (or Ctrl-click) the letitbrew icon in Applications.
- Select "Open" from the menu.
- Click "Open" again in the popup.

The app will now launch.

---

## 🖥️ System Requirements

- macOS 13 (Ventura) or later
- At least 100 MB of free space
- Claude Code or Codex installed and configured (optional but recommended)
- Apple Silicon or Intel Mac (both supported)

---

## 🧰 How to Use It Daily

You do not need to do anything once it is running. Start Claude Code or Codex, and letitbrew will automatically detect their activity. You can close the app by clicking the coffee icon and choosing "Quit." It will also start automatically each time you log in to your Mac.

---

## 🛠️ Troubleshooting

**I don't see the coffee icon after launching.**
Check your menu bar. The icon is small and sits near the clock. If you still don't see it, check if the app is running by opening Activity Monitor (use Spotlight to find it) and look for "letitbrew." If it is not there, try launching the app again from Applications.

**The app says "No permission" or asks for access.**
Go to System Settings > Privacy & Security. Look for "Notifications" or "Auxiliary Control" and make sure letitbrew is enabled. Restart the app after changing settings.

**My Mac still sleeps even when an agent is running.**
Make sure you are using a recent version of the app. Also verify that Claude Code or Codex is actually running (not paused or waiting for input). If the agent is sitting idle at a prompt, the app may consider it as not working.

**I want to uninstall the app.**
Drag the letitbrew app from Applications to the Trash. Also check your menu bar for the icon, right-click it, and choose "Quit" first if possible.

---

## 🔒 Privacy & Security

letitbrew runs entirely on your Mac. It does not upload data anywhere. It does not track your activity. It only looks at the process list to see if Claude Code or Codex is active. Your code, prompts, and conversations are never read or transmitted.

---

## 📄 License & Credits

letitbrew is open source. It uses Apple's XPC framework and SwiftUI for the interface. The project is maintained on GitHub. If you are curious about the technical details, you can explore the source code in the repository.

---

## 📣 Feedback & Support

If you encounter any issues or have ideas for improvement, visit the repository's Issues section on GitHub. You can also leave a star to support the developers.

---

## 🗂️ Related Tools

If you like letitbrew, you might also be interested in other power-management utilities for developers, such as Amphetamine or Caffeine. However, letitbrew stands out because it is context-aware of your AI agents specifically.

---

Keywords: agentic-ai, ai-agents, caffeine, claude-code, codex, developer-tools, keep-awake, launchd, macos, macos-app, menubar, power-management, swift, swiftui, xpc