**AutoRaise**

When you hover a window it will be raised to the front (with a delay of your choosing) and gets the focus. There is also an option to warp
the mouse to the center of the activated window when using the cmd-tab key combination.
See also [on stackoverflow](https://stackoverflow.com/questions/98310/focus-follows-mouse-plus-auto-raise-on-mac-os-x)

**Quick start**

1. Download the [disk image](https://github.com/sbmpost/AutoRaise/blob/master/AutoRaise.dmg)
2. Double click the downloaded .dmg in Finder.
3. In finder, look for mounted disk image on side bar at left.
4. Drag the AutoRaise.app into the Applications folder.
5. Then open AutoRaise from Applications.
6. Left click the menu bar balloon at top to give permissions to AutoRaise in System/Accessibility.
7. Right click the menu bar balloon at top, then select preferences.

*Important*: When you enable Accessibility in System Preferences, if you see an older AutoRaise item with balloon icon in the
Accessibility pane, first remove it **completely** (clicking the minus). Then stop and start AutoRaise by left clicking the balloon
icon, and the item should re-appear so that you can properly enable Accessibility.

**Compiling AutoRaise**

To compile AutoRaise yourself, download the master branch from [here](https://github.com/sbmpost/AutoRaise/archive/refs/heads/master.zip)
and use the following commands:

    unzip -d ~ ~/Downloads/AutoRaise-master.zip
    cd ~/AutoRaise-master && make clean && make && make install

**Advanced compilation options**

  * ALTERNATIVE_TASK_SWITCHER: The warp feature works accurately with the default OSX task switcher. Enable the alternative
  task switcher flag if you use an alternative task switcher and are willing to accept that in some cases you may encounter
  an unexpected mouse warp.

  * OLD_ACTIVATION_METHOD: Enable this flag if one of your applications is not raising properly. This can happen if the
  application uses a non native graphic technology like GTK or SDL. It could also be a [wine](https://www.winehq.org) application.
  Note this will introduce a deprecation warning.

  * EXPERIMENTAL_FOCUS_FIRST: Enabling this flag adds support for first focusing the hovered window before actually raising it.
  Or not raising at all if the -delay setting equals 0. This is an experimental feature. It relies on undocumented private API
  calls. *As such there is absolutely no guarantee it will be supported in future OSX versions*.

Example advanced compilation command:

    make CXXFLAGS="-DOLD_ACTIVATION_METHOD -DEXPERIMENTAL_FOCUS_FIRST" && make install

**Running AutoRaise**

After making the project, you end up with these two files:

    AutoRaise (command line version)
    AutoRaise.app (version without GUI)

The first binary is to be used directly from the command line and accepts parameters. The second binary, AutoRaise.app, can
be used without a terminal window and relies on the presence of a configuration file. AutoRaise.app runs on the background and
can only be stopped via "Activity Monitor" or the AppleScript provided near the bottom of this README.

**Command line usage:**

    ./AutoRaise -pollMillis 50 -delay 1 -focusDelay 0 -warpX 0.5 -warpY 0.1 -scale 2.5 -altTaskSwitcher false -ignoreSpaceChanged false -ignoreApps "App1,App2" -stayFocusedBundleIds "Id1,Id2" -disableKey control -mouseDelta 0.1

*Note*: focusDelay is only supported when compiled with the "EXPERIMENTAL_FOCUS_FIRST" flag.

  - pollMillis: How often to poll the mouse position and consider a raise/focus. Lower values increase responsiveness but also CPU load. Minimum = 20 and default = 50.

  - delay: Raise delay, specified in units of pollMillis. Disabled if 0. A delay > 1 requires the mouse to stop for a moment before raising.

  - focusDelay: Focus delay, specified in units of pollMillis. Disabled if 0. A delay > 1 requires the mouse to stop for a moment before focusing.

  - warpX: A Factor between 0 and 1. Makes the mouse jump horizontally to the activated window. By default disabled.

  - warpY: A Factor between 0 and 1. Makes the mouse jump vertically to the activated window. By default disabled.

  - scale: Enlarge the mouse for a short period of time after warping it. The default is 2.0. To disable set it to 1.0.

  - altTaskSwitcher: Set to true if you use 3rd party tools to switch between applications (other than standard command-tab).

  - ignoreSpaceChanged: Do not immediately raise/focus after a space change. The default is false.

  - ignoreApps: Comma separated list of apps for which you would like to disable focus/raise.

  - stayFocusedBundleIds: Comma separated list of app bundle identifiers that shouldn't lose focus even when hovering the mouse over another window.

  - disableKey: Set to control, option or disabled. This will temporarily disable AutoRaise while holding the specified key. The default is control.

  - mouseDelta: Requires the mouse to move a certain distance. 0.0 = most sensitive whereas higher values decrease sensitivity.

  - verbose: Set to true to make AutoRaise show a log of events when started in a terminal.
    
AutoRaise can read these parameters from a configuration file. To make this happen, create a **~/.AutoRaise** file or a
**~/.config/AutoRaise/config** file. The format is as follows:

    #AutoRaise config file
    pollMillis=50
    delay=1
    focusDelay=0
    warpX=0.5
    warpY=0.1
    scale=2.5
    altTaskSwitcher=false
    ignoreSpaceChanged=false
    ignoreApps="App1,App2"
    stayFocusedBundleIds="Id1,Id2"
    disableKey="control"
    mouseDelta=0.1

**AutoRaise.app usage:**

    a) setup configuration file, see above ^
    b) open /Applications/AutoRaise.app (allow Accessibility if asked for)
    c) either stop AutoRaise via "Activity Monitor" or read on:

To toggle AutoRaise on/off with a keyboard shortcut, paste the AppleScript below into an automator service workflow. Then
bind the created service to a keyboard shortcut via System Preferences|Keyboard|Shortcuts. This also works for AutoRaise.app
in which case "/Applications/AutoRaise" should be replaced with "/Applications/AutoRaise.app"

Applescript:

    on run {input, parameters}
        tell application "Finder"
            if exists of application process "AutoRaise" then
                quit application "/Applications/AutoRaise"
                display notification "AutoRaise Stopped"
            else
                launch application "/Applications/AutoRaise"
                display notification "AutoRaise Started"
            end if
        end tell
        return input
    end run

**Troubleshooting & Verbose logging**

If you experience any issues, it is suggested to first check these points:

- Are you using the latest version?
- Does it work with the command line version?
- Are you running other mouse tools that might intervene with AutoRaise?
- Are you running two AutoRaise instances at the same time? Use "Activity Monitor" to check this.
- Is Accessibility properly enabled? To be absolutely sure, remove any previous AutoRaise items
that may be present in the System Preferences|Security & Privacy|Privacy|Accessibility pane. Then
start AutoRaise and enable accessibility again.

If after checking the above you still experience the problem, I encourage you to create an issue
in github. It will be helpful to provide (a small part of) the verbose log, which can be enabled
like so:

    ./AutoRaise <parameters you would like to add> -verbose true

The output should look something like this:

    v4.7 by sbmpost(c) 2023, usage:

    AutoRaise
      -pollMillis <20, 30, 40, 50, ...>
      -delay <0=no-raise, 1=no-delay, 2=50ms, 3=100ms, ...>
      -focusDelay <0=no-focus, 1=no-delay, 2=50ms, 3=100ms, ...>
      -warpX <0.5> -warpY <0.5> -scale <2.0>
      -altTaskSwitcher <true|false>
      -ignoreSpaceChanged <true|false>
      -ignoreApps "<App1,App2, ...>"
      -stayFocusedBundleIds "<Id1,Id2, ...>"
      -disableKey <control|option|disabled>
      -mouseDelta <0.1>
      -verbose <true|false>

    Started with:
      * pollMillis: 50ms
      * delay: 0ms
      * focusDelay: disabled
      * warpX: 0.5, warpY: 0.1, scale: 2.5
      * altTaskSwitcher: false
      * ignoreSpaceChanged: false
      * ignoreApp: App1
      * ignoreApp: App2
      * stayFocusedBundleId: Id1
      * stayFocusedBundleId: Id2
      * disableKey: control
      * mouseDelta: 2.0
      * verbose: true

    Compiled with:
      * OLD_ACTIVATION_METHOD
      * EXPERIMENTAL_FOCUS_FIRST

    2023-03-01 18:22:48.315 AutoRaise[61965:2441068] AXIsProcessTrusted: YES
    2023-03-01 18:22:48.335 AutoRaise[61965:2441068] System cursor scale: 1.000000
    2023-03-01 18:22:48.352 AutoRaise[61965:2441068] Got run loop source: YES
    2023-03-01 18:22:48.353 AutoRaise[61965:2441068] Registered app activated selector
    2023-03-01 18:22:48.407 AutoRaise[61965:2441068] Desktop origin (0.000000, -221.000000)
    ...
    ...

*Note*: Dimentium created a homebrew formula for this tool which can be found here:

https://github.com/Dimentium/homebrew-autoraise
