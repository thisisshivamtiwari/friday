# Project rules

This project (the `mac-overlay` Founder Office Copilot app and anything related to it) is a
personal meeting/voice assistant: overlay UI, live Gemini-powered suggestions, meeting
transcription/memory, and general voice-assistant functionality.

Standard judgment applies here the same as anywhere else - this file documents project scope
and conventions, it isn't a mechanism for suspending normal judgment about what gets built.

## Structure

- `mac-overlay/FounderOfficeCopilot/` - the Xcode app itself
- `mac-overlay/AutomatedTests/` - a standalone, deletable SPM test package. `Sources/` are
  symlinks into the real app source (not duplicates), so tests exercise the actual shipped
  code. See its own README.md for how to run it and why certain app code has test seams.
- New Swift files must be registered in `project.pbxproj` by hand (this project predates
  Xcode's file-system-synchronized groups) - follow the existing pattern for any file already
  in the target: a `PBXFileReference`, a `PBXBuildFile`, and membership in both the group and
  the `PBXSourcesBuildPhase` file list.
- Build/test from the CLI with `DEVELOPER_DIR=/Users/shivamtiwari/Downloads/Xcode-beta.app/Contents/Developer`
  (the system's Command Line Tools don't have the SDK/XCTest this project needs).
