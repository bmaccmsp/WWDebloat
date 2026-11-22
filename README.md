# WWDebloat

Removes consumer bloatware, ads and AI features from Windows 10 and Windows 11 workstations, then cleans up disk space. It is built to run unattended from NinjaOne (or any RMM) as SYSTEM, and it never weakens a security control.

## At a glance

| | |
|---|---|
| **Script** | `WWDebloat.ps1` |
| **Runs on** | Windows 10 / 11 workstations only. Refuses to run on Windows Server. |
| **Runs as** | SYSTEM (or any administrator), Windows PowerShell 5.1, 64-bit |
| **Internet access** | None. The script downloads nothing. |
| **Restart** | Not forced. Some changes appear after the next restart or sign-in. |
| **Log** | `C:\ProgramData\WWDebloat\Logs\WWDebloat_<date>_<time>.log` (last 20 kept) |

## What it never touches

The script contains no code that changes any of the following:

- BitLocker
- Microsoft Defender (no settings, exclusions, sample submission or cloud protection)
- Windows Firewall
- Windows Update and update services
- Windows services of any kind
- The Windows diagnostic data (telemetry) level, which Defender for Endpoint and Intune reporting depend on
- SSH, RDP or any other remote-access or listening service
- SmartScreen, UAC, credential or password settings

At the end of every run it writes a **read-only** Defender and BitLocker status line to the log so you can confirm both are still on.

## What it does

The script runs in four stages. Each stage can be skipped (see [Options](#options)).

### 1. Restore point

Turns on System Protection for the system drive if it is off, then creates a restore point named `WWDebloat 1.0.0 pre-change` before anything else changes.

Windows normally refuses to create a restore point if one was made in the last 24 hours. The script lifts that limit for this single restore point and then puts the original setting back.

If the restore point cannot be created (for example on a VM with System Protection unavailable), the script logs a warning and continues.

> A restore point rolls back registry and system file changes. It does **not** bring back removed Store apps. Reinstall those from the Microsoft Store if needed.

### 2. App removal

Each app below is removed in three ways so it stays gone:

1. **Installed copies** are removed for every user on the PC.
2. **The provisioned copy** is removed, so new user profiles do not get the app.
3. **A Deprovisioned registry marker** is written (Microsoft's documented method), so Windows feature updates do not reinstall it.

Apps are matched by exact package name, never by wildcard, so nothing with a similar name is removed by accident.

| App | Package name |
|---|---|
| Xbox App | `Microsoft.GamingApp` |
| Xbox Console Companion (Windows 10) | `Microsoft.XboxApp` |
| Xbox Game Bar | `Microsoft.XboxGamingOverlay` |
| Xbox Game Bar Plugin (Windows 10) | `Microsoft.XboxGameOverlay` |
| Xbox Speech To Text Overlay | `Microsoft.XboxSpeechToTextOverlay` |
| Xbox TCUI | `Microsoft.Xbox.TCUI` |
| Solitaire Collection | `Microsoft.MicrosoftSolitaireCollection` |
| News | `Microsoft.BingNews` |
| Weather | `Microsoft.BingWeather` |
| Bing Search | `Microsoft.BingSearch` |
| Start Experiences App | `Microsoft.StartExperiencesApp` |
| Clipchamp | `Clipchamp.Clipchamp` |
| Media Player | `Microsoft.ZuneMusic` |
| Movies & TV | `Microsoft.ZuneVideo` |
| Sound Recorder | `Microsoft.WindowsSoundRecorder` |
| Feedback Hub | `Microsoft.WindowsFeedbackHub` |
| Dev Home | `Microsoft.Windows.DevHome` |
| Power Automate | `Microsoft.PowerAutomateDesktop` |
| Quick Assist | `MicrosoftCorporationII.QuickAssist` (plus the older built-in Windows 10 capability) |
| Phone Link | `Microsoft.YourPhone` |
| Mobile Devices | `MicrosoftWindows.CrossDevice` |

Also in this stage:

- **Game DVR is turned off by policy** (`AllowGameDVR = 0`). Without this, Windows shows an "ms-gamebar" popup when a game launches after Game Bar is removed.
- Packages that Windows marks as non-removable are skipped and noted in the log. This is a warning, not an error.

**Why Quick Assist and Phone Link?** Scammers posing as tech support routinely talk users into opening Quick Assist so they can take remote control of the PC, so removing it is a security improvement when the PC is supported through an RMM. Phone Link and Mobile Devices sync messages, photos and notifications between the PC and personal phones, which is a data-leak path on business PCs.

### 3. Tweaks

Per-user settings are written to **every existing user profile** (including users who are not signed in) and to the **Default profile**, so accounts created later get them too. This matters because the script runs as SYSTEM, which has its own separate user registry.

#### Disable Windows Consumer Features

Stops Windows from silently installing sponsored apps and games and from suggesting apps in Start.

| Setting | Value |
|---|---|
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent\DisableWindowsConsumerFeatures` | 1 |
| Per user, `...\ContentDeliveryManager\SilentInstalledAppsEnabled` | 0 |
| Per user, `...\ContentDeliveryManager\PreInstalledAppsEnabled` | 0 |
| Per user, `...\ContentDeliveryManager\OemPreInstalledAppsEnabled` | 0 |
| Per user, `...\ContentDeliveryManager\SystemPaneSuggestionsEnabled` | 0 |
| Per user, `...\ContentDeliveryManager\SubscribedContent-338388Enabled` | 0 |

Windows only fully honors the machine policy on Enterprise and Education editions. The per-user settings cover Pro.

#### Remove Windows AI

| Change | Effect |
|---|---|
| Removes `Microsoft.Copilot`, the legacy Copilot provider and `Microsoft.MicrosoftOfficeHub` | Removes the Copilot app and the "Microsoft 365 Copilot" launcher app. Desktop Word, Excel, Outlook and Teams are **not** affected. |
| `TurnOffWindowsCopilot = 1` (machine and per user) | Turns off Windows Copilot |
| Per user `ShowCopilotButton = 0` | Hides the Copilot taskbar button |
| `WindowsAI\DisableAIDataAnalysis = 1` | Recall cannot save screen snapshots |
| `WindowsAI\AllowRecallEnablement = 0` | Recall cannot be turned on |
| `WindowsAI\DisableClickToDo = 1` | Turns off Click to Do |
| `WindowsAI\DisableSettingsAgent = 1` | Turns off the AI agent in Settings |
| `WindowsNotepad\DisableAIFeatures = 1` | Turns off AI features in Notepad |
| `Policies\Paint\DisableCocreator`, `DisableGenerativeFill`, `DisableImageCreator` = 1 | Turns off AI features in Paint |
| Disables the `Recall` optional feature if enabled | Copilot+ PCs only. Disabled, not deleted, so it can be turned back on |

Recall is a particular concern for any firm handling confidential client data, because it records periodic screenshots of everything on screen.

#### Debloat Microsoft Edge

Machine policies under `HKLM\SOFTWARE\Policies\Microsoft\Edge`. None of them touch SmartScreen, passwords, extensions or any security setting.

| Policy | Value | Effect |
|---|---|---|
| `HideFirstRunExperience` | 1 | No first-run setup wizard |
| `ShowRecommendationsEnabled` | 0 | No feature and promo popups |
| `PersonalizationReportingEnabled` | 0 | Browsing activity not used for ad personalization |
| `UserFeedbackAllowed` | 0 | No "send feedback" prompts |
| `DiagnosticData` | 0 | No optional Edge diagnostic data |
| `ConfigureDoNotTrack` | 1 | Sends Do Not Track |
| `AlternateErrorPagesEnabled` | 0 | No suggestion pages for mistyped addresses |
| `EdgeCollectionsEnabled` | 0 | Turns off Collections |
| `EdgeShoppingAssistantEnabled` | 0 | Turns off coupons and price comparison |
| `MicrosoftEdgeInsiderPromotionEnabled` | 0 | No Edge Insider promotions |
| `ShowMicrosoftRewards` | 0 | No Microsoft Rewards |
| `WebWidgetAllowed` | 0 | No Edge search bar widget on the desktop |
| `WalletDonationEnabled` | 0 | No donation prompts |
| `DefaultBrowserSettingsCampaignEnabled` | 0 | No "make Edge your default" campaigns |
| `EdgeUpdate\CreateDesktopShortcutDefault` | 0 | Edge updates do not recreate the desktop shortcut |

Edge will show "Your browser is managed by your organization" once these are set. That is expected.

#### Remove Widgets

- Removes the Widgets packages (`MicrosoftWindows.Client.WebExperience`, `Microsoft.WidgetsPlatformRuntime`).
- Sets `HKLM\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests = 0` (Windows 11 Widgets).
- Sets `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds\EnableFeeds = 0` (Windows 10 News and Interests).

#### Disable WPBT

Sets `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\DisableWpbtExecution = 1`.

WPBT (Windows Platform Binary Table) lets a PC's firmware hand Windows a program to run at every boot, silently and with full system rights. PC makers use it for anti-theft agents and bundled utilities, and security researchers have shown it can be abused to run malicious code that survives a full Windows reinstall. Disabling it is a security improvement. The only side effect: if a client relies on a firmware-based anti-theft product (for example Absolute), that product's agent will not start.

#### Block Logitech Download Assistant

Windows Update installs this with Logitech device drivers, and it nags users to install Logitech software. Logitech keyboards and mice work normally without it. The script:

- Stops the `logi_download_assistant` process.
- Removes its startup entry if present.
- Empties `C:\Program Files\LogiDownloadAssistant` and denies write access to it, so driver updates cannot put it back.

#### Start menu recommendations

**What this does:** removes the *promotional* content from the Recommended area of the Windows 11 Start menu, and leaves the *useful* content.

| Removed | Kept |
|---|---|
| Recommended websites (`HideRecommendedPersonalizedSites = 1`) | Recently opened files |
| Tips, shortcuts and new app suggestions (per user `Start_IrisRecommendations = 0`) | Recently added and most used apps |
| Microsoft account, OneDrive backup and similar nags (per user `Start_AccountNotifications = 0`) | Jump Lists and Recent files in File Explorer |

Recent files are kept on purpose: turning them off also removes Jump Lists and the Recent list in File Explorer, which people use constantly.

**Opt-in: hide the whole Recommended section.** Set `HideStartRecommendedSection` to remove the section entirely. Windows officially honors this only on Education and SE editions, so the script also sets `PolicyManager\current\device\Education\IsEducationEnvironment = 1`, which tells Windows the PC is in an education environment. That flag can change other behaviors; the reported side effect is that Windows Spotlight on the lock screen stops working. Test it on one PC before rolling it out.

#### Bing in Windows Search

**What this does:** typing in the Start menu or taskbar search box searches the PC only. Results no longer include Bing web results, web suggestions or "search highlights" (the daily trivia and doodles in the search box). Searching for apps, files and settings works exactly as before.

| Setting | Value |
|---|---|
| Per user `HKCU\Software\Microsoft\Windows\CurrentVersion\Search\BingSearchEnabled` | 0 |
| Per user `HKCU\Software\Policies\Microsoft\Windows\Explorer\DisableSearchBoxSuggestions` | 1 |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search\EnableDynamicContentInWSB` | 0 |

Side effect: `DisableSearchBoxSuggestions` also stops the File Explorer search box from suggesting your previous searches.

### 4. Cleanup

#### Disk Cleanup

**What this does:** runs the built-in Windows Disk Cleanup tool silently, limited to handlers that only remove throwaway files. The script writes its own Disk Cleanup profile (number 4729) and sets every handler explicitly, so a leftover setting can never include something unsafe.

| Cleaned | Not cleaned (and why) |
|---|---|
| Temporary Files, Temporary Setup Files | **Downloads folder**: user files |
| Windows Update Cleanup (superseded updates) | **Recycle Bin**: users expect to recover deleted files |
| Delivery Optimization cache | **Internet Cache**: Outlook keeps copies of opened email attachments here, including unsaved edits |
| Thumbnail cache, DirectX shader cache | **Memory dumps, Windows Error Reporting files**: needed when investigating crashes or incidents |
| Setup logs, upgrade logs, old CHKDSK files | **Previous Windows installation, old driver packages**: needed to roll back an upgrade or a bad driver |
| Downloaded Program Files, Active Setup temp, Diagnostic Data Viewer database | **Windows ESD files**: needed for "Reset this PC" |

Disk Cleanup is stopped if it runs longer than 45 minutes.

#### Component store cleanup

**What this does:** runs `DISM /Online /Cleanup-Image /StartComponentCleanup`, which deletes old versions of Windows components left behind after updates. Installed updates can still be uninstalled afterward, so a bad Patch Tuesday update can still be rolled back.

**Opt-in:** `ResetComponentBase` adds `/ResetBase`, which frees more space but makes **every installed update permanently uninstallable**. Not recommended for routine use.

DISM is never given a timeout, because interrupting it mid-run can damage the component store.

#### Temp files

**What this does:** deletes files older than 7 days (configurable) from:

- `C:\Windows\Temp`
- `C:\Users\<each user>\AppData\Local\Temp`

Details:

- Recent files are kept because running installers and open applications use them.
- Files in use are skipped silently.
- Folders left empty are removed. The Temp folders themselves stay.
- **Junctions and symbolic links are never followed.** The script runs as SYSTEM in folders users can write to, and following a link planted there would let someone aim the deletion at any file on the PC.

## Options

Set options either as script parameters or as NinjaOne script variables with the **same name**. A NinjaOne variable always wins over a parameter.

| Name | Type | Default | Effect |
|---|---|---|---|
| `SkipRestorePoint` | Checkbox / switch | Off | Do not create a restore point |
| `SkipAppRemoval` | Checkbox / switch | Off | Do not remove apps |
| `SkipTweaks` | Checkbox / switch | Off | Do not apply tweaks |
| `SkipCleanup` | Checkbox / switch | Off | Do not run Disk Cleanup, DISM or temp cleanup |
| `HideStartRecommendedSection` | Checkbox / switch | Off | Hide the entire Start menu Recommended section (see caveat above) |
| `ResetComponentBase` | Checkbox / switch | Off | Add `/ResetBase` to DISM (updates become uninstallable) |
| `TempFileAgeDays` | Integer | 7 | Minimum age, in days, of temp files to delete (1 to 365) |

Command-line example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WWDebloat.ps1 -SkipCleanup -TempFileAgeDays 14
```

## NinjaOne setup

1. **Administration > Library > Automation > Add > New Script.**
2. **Language:** PowerShell. **Operating system:** Windows. **Architecture:** 64-bit.
3. **Run As:** System.
4. Paste the contents of `WWDebloat.ps1`.
5. Optional: add **Script Variables** named exactly as in the [Options](#options) table (checkboxes for the switches, an integer for `TempFileAgeDays`).
6. When running it, set a **timeout of at least 60 minutes**. Disk Cleanup and DISM can be slow on PCs that have never been cleaned.

If NinjaOne runs the script in 32-bit PowerShell by mistake, the script relaunches itself in 64-bit PowerShell automatically.

The full log appears in the NinjaOne activity output and is also saved on the PC under `C:\ProgramData\WWDebloat\Logs`.

**Recommended rollout:** run it on one or two pilot PCs first, confirm users can still work normally, then deploy to the rest.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Completed with no errors (warnings are possible; check the log) |
| 1 | Completed, but one or more steps failed. Each failure is a line marked `[ERROR]` in the log |
| 2 | Refused to run: not a workstation, not elevated, or not Windows PowerShell 5.1. Nothing was changed |

Running the script again is safe. It only redoes what is still needed.

## Reverting a change

| To undo | Do this |
|---|---|
| Everything except app removals | Restore the `WWDebloat ... pre-change` restore point (System Properties > System Protection > System Restore) |
| A removed app | Delete `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\<package family name>`, then install the app from the Microsoft Store |
| A policy or setting | Delete the registry value listed in this README, then restart |
| Logitech block | Remove the deny entry: `icacls "C:\Program Files\LogiDownloadAssistant" /remove:d *S-1-1-0` |
| Recall | `Enable-WindowsOptionalFeature -Online -FeatureName Recall`, and delete the `WindowsAI` policy values |

## Requirements and limitations

- Windows 10 or Windows 11 (Pro, Enterprise or Education). Windows Server is refused on purpose.
- Windows PowerShell 5.1 (included with Windows). PowerShell 7 is refused, because some of the cmdlets used are unreliable there.
- Administrator or SYSTEM rights.
- Changes to Start, taskbar and search appear after users sign out and back in, or after a restart. The script never restarts the PC or restarts Explorer, so nobody loses work mid-session.
- If a policy in this script conflicts with one deployed by Intune or Group Policy, the managed policy wins at the next policy refresh.
