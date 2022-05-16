When you hover a window it will be raised to the front (with a delay of your choosing) and gets the focus. There is also an
option to warp the mouse to the center of the activated window when using the cmd-tab key combination. See also
https://stackoverflow.com/questions/98310/focus-follows-mouse-plus-auto-raise-on-mac-os-x

**Compiling AutoRaise**

To use AutoRaise, download the master branch from [here](https://github.com/sbmpost/AutoRaise/archive/refs/heads/master.zip)
and use the following commands to compile the binaries:

    unzip -d ~ ~/Downloads/AutoRaise-master.zip
    cd ~/AutoRaise-master && make clean && make

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

    make CXXFLAGS="-DOLD_ACTIVATION_METHOD -EXPERIMENTAL_FOCUS_FIRST"

**Running AutoRaise**

After making the project, you end up with these two files:

    AutoRaise
    AutoRaise.app

AutoRaise can be used directly from the command line in which case it accepts command line parameters. The other binary,
AutoRaise.app, can be used without a terminal window and relies on the presence of a configuration file. Note also that
AutoRaise.app runs on the background and can only be stopped via "Activity Monitor" or the AppleScript provided near the
bottom of this README.

**Command line usage:**

    ./AutoRaise -delay 1 -warpX 0.5 -warpY 0.1 -scale 2.5 -mouseStop false

The delay is specified in units of 50ms and the warp parameters are factors between 0 and 1. If you only would like to use
the warp feature, simply set delay to 0. When warping the mouse, the scale parameter allows you to specify the mouse cursor
size. To disable this, set it to the system configured scale (normally 1.0). If no parameters have been specified, AutoRaise
disables warp and defaults to -delay 1 (i.e. no delay). If the mouseStop flag is set, AutoRaise requires the mouse to stop
moving for a moment before raising. Responsiveness will be lower but in return you will be able to select top menubar items
even if there is another application 'in the way'. To pass the command line parameters by means of a file, create either a
**~/.AutoRaise** file or a **~/.config/AutoRaise/config** file. The file format is as follows:

    #AutoRaise config file
    delay=1 
    warpX=0.5
    warpY=0.1
    scale=2.5
    mouseStop=false

**AutoRaise.app usage:**

    a) setup configuration file, see above ^
    b) in the AutoRaise source folder run: make install
    c) open /Applications/AutoRaise.app (allow Accessibility if asked for)
    d) either stop AutoRaise via "Activity Monitor" or read on:

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

    ./AutoRaise -delay 1 -warpX 0.5 -warpY 0.1 -scale 2.5 -mouseStop false -verbose true

The output should look something like this:

    v3.0 by sbmpost(c) 2022, usage:

    AutoRaise
      -delay <0=no-raise, 1=no-delay, 2=50ms, 3=100ms, ...>
      -warpX <0.5> -warpY <0.5> -scale <2.0>
      -mouseStop <true|false>
      -verbose <true|false>

    Started with:
      * delay: 0ms
      * warpX: 0.5, warpY: 0.1, scale: 2.5
      * mouseStop: false
      * verbose: true

    Compiled with:
      * OLD_ACTIVATION_METHOD
      * EXPERIMENTAL_FOCUS_FIRST
      * ALTERNATIVE_TASK_SWITCHER

    2022-05-16 17:55:02.169 AutoRaise[57228:908941] AXIsProcessTrusted: YES
    2022-05-16 17:55:02.190 AutoRaise[57228:908941] System cursor scale: 1.000000
    2022-05-16 17:55:02.208 AutoRaise[57228:908941] Got run loop source: YES
    2022-05-16 17:55:02.209 AutoRaise[57228:908941] Registered app activated selector
    2022-05-16 17:55:02.251 AutoRaise[57228:908941] Desktop origin (-1280.000000, 0.000000)
    ...
    ...

*Note1*: Dimentium created a homebrew formula for this tool which can be found here:

https://github.com/Dimentium/homebrew-autoraise

*Note2*: Lothar Haeger created a gui on top of the command line version which can be found here:

https://github.com/lhaeger/AutoRaise
