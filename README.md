When you hover a window it will be raised to the front (with a delay of your choosing) and gets the focus. There is also an
option to warp the mouse to the center of the activated window, using the cmd-tab key combination for example. To use AutoRaise,
follow these instructions:

    a) download https://github.com/sbmpost/AutoRaise/archive/refs/heads/master.zip
    b) unzip -d ~ ~/Downloads/AutoRaise-master.zip
    c) cd ~/AutoRaise-master && make clean && make

This will give you two files:

    AutoRaise
    AutoRaise.app

AutoRaise can be used directly from the command line in which case it accepts command line parameters. AutoRaise.app can be used
without a terminal window and relies on the presence of two configuration files. Another difference is that AutoRaise.app runs on
the background and can only be stopped via "Activity Monitor" or the AppleScript provided at the bottom of this README.

Command line usage:

    ./AutoRaise -delay 1 -warpX 0.5 -warpY 0.5

The delay is specified in units of 20ms and the warp parameters are factors between 0 and 1. If no delay has been specified,
AutoRaise first looks for an AutoRaise.delay file in the **home** folder and defaults to 40ms if it can't find one. Likewise,
AutoRaise checks for the existence of an AutoRaise.warp. So in order to pass the parameters from above now and in the future,
it will be sufficient to run these commands once:

    echo 1 > ~/AutoRaise.delay
    echo "0.5 0.5" > ~/AutoRaise.warp

AutoRaise.app usage:

    a) setup configuration files, see above ^
    b) cp AutoRaise.app /Applications/
    c) run AutoRaise.app (and allow Accessibility access if asked)
    d) either stop AutoRaise via "Activity Monitor" or read on:

To toggle AutoRaise on/off with a keyboard shortcut, paste the AppleScript below into an automator service workflow. Then
bind the created service to a keyboard shortcut of your own choice via System Preferences|Keyboard|Shortcuts. This also
applies for AutoRaise.app in which case "/Applications/AutoRaise" should be replaced with "/Applications/AutoRaise.app"

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

*Note*: When upgrading from a previous AutoRaise version, it is a good idea to check you are not running two instances
at the same time (the older and the new version). This can always be checked with "Activity Monitor"

See also https://stackoverflow.com/questions/98310/focus-follows-mouse-plus-auto-raise-on-mac-os-x
