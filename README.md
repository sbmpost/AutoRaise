When you hover a window it will be raised to the front (with a delay of your choosing) and gets the focus. There is
also an option to warp the mouse to the center of the activated window. To use it, copy the AutoRaise binary to your
/Applications/ folder making sure it is executable (chmod 700 AutoRaise). Then double click it from within Finder.
To quickly toggle it on/off you can use the applescript below and paste it into an automator service workflow. Then
bind the created service to a keyboard shortcut via System Preferences|Keyboard|Shortcuts.

Applescript usage:

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

Command line usage:

    ./AutoRaise -delay 2 -warp

*Note1*: If no delay has been specified on the command line, AutoRaise will look for an AutoRaise.delay file in the **home** folder. It will also check for the existence of an AutoRaise.warp file. This is particularly useful for the applescript usage as described above because 'launch application' does not support command line arguments. The delay should be specified in units of 20ms. For example to specify a delay of 40ms run this command once in a terminal: 'echo 2 > ~/AutoRaise.delay'. To enable warp, run this command: 'touch ~/AutoRaise.warp'.

*Note2*: If you are not comfortable running the provided binary, then you can compile it yourself using this command:

    g++ -O2 -Wall -fobjc-arc -o AutoRaise AutoRaise.mm -framework AppKit

See also https://stackoverflow.com/questions/98310/focus-follows-mouse-plus-auto-raise-on-mac-os-x
