When you hover a window it will be raised to the front (with a delay of your choosing) and gets the focus. There is also an
option to warp the mouse to the center of the activated window when using the cmd-tab key combination. To use AutoRaise, you
can download the master branch from [here](https://github.com/sbmpost/AutoRaise/archive/refs/heads/master.zip) and use these
commands to compile the binaries:

    unzip -d ~ ~/Downloads/AutoRaise-master.zip
    cd ~/AutoRaise-master && make clean && make

This will give you two files:

    AutoRaise
    AutoRaise.app

AutoRaise can be used directly from the command line in which case it accepts command line parameters. AutoRaise.app can be used
without a terminal window and therefore relies on the presence of two configuration files. Another difference is that AutoRaise.app
runs on the background and can only be stopped via "Activity Monitor" or the AppleScript provided at the bottom of this README.

Command line usage:

    ./AutoRaise -delay 1 -warpX 0.5 -warpY 0.1 -scale 2.5

The delay is specified in units of 20ms and the warp parameters are factors between 0 and 1. If the mouse is warped, the scale
parameter allows you to specify the mouse cursor size. To disable the scaling feature, simply set the value equal to the system
configured scale (normally 1.0). If no parameters have been specified, AutoRaise first looks for an AutoRaise.delay file in the
**home** folder and defaults to 40ms delay if it can't find one. Likewise, it will check for the existence of an AutoRaise.warp
file. In order to pass the parameters from the example above by means of these configuration files, run these commands once:

    echo 1 > ~/AutoRaise.delay
    echo "0.5 0.1 2.5" > ~/AutoRaise.warp

Update (2021-04-17): 
In addition to the configuration files mentioned above, AutoRaise now supports hidden configuration files in these locations: **~/.AutoRaise** or **~/.config/AutoRaise/config**. The format of these files is as follows:

    #AutoRaise config file
    delay=1 
    warpX=0.5
    warpY=0.3
    scale=8

AutoRaise.app usage:

    a) setup configuration files, see above ^
    b) cp -r AutoRaise.app /Applications/
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

*Note*: When upgrading from a previous AutoRaise version, it is a good idea to check if you are not running two instances
at the same time (the older and the new version). This can always be checked with "Activity Monitor". It may also be
necessary to toggle off and on access for AutoRaise in the System Preferences|Security & Privacy|Privacy|Accessibility pane. 

See also https://stackoverflow.com/questions/98310/focus-follows-mouse-plus-auto-raise-on-mac-os-x
