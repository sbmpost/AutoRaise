When you hover a window it will be raised to the front (with a delay of your choosing) and gets the focus.
To use it, copy the AutoRaise binary to your /Applications/ folder making sure it is executable (chmod 700 AutoRaise).
Then double click it from within Finder. To quickly toggle it on/off you can use the applescript below and paste it
into an automator service workflow. Then bind the created service to a keyboard shortcut via
System Preferences|Keyboard|Shortcuts.

Note: If no delay has been specified on the command line, AutoRaise will look for an AutoRaise.delay file in the **home**
folder. This is particularly useful when using the applescript below because 'launch application' does not support
command line arguments. The delay should be specified in units of 50ms. For example to specify a delay of 150ms run
this command once in a terminal: 'cd ~; echo 3 > AutoRaise.delay'

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

See also https://stackoverflow.com/questions/98310/focus-follows-mouse-plus-auto-raise-on-mac-os-x
