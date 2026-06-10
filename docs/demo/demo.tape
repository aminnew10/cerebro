# vhs tape that renders docs/demo.gif from the scripted session in demo.sh.
# Regenerate with:  cd docs/demo && vhs demo.tape

Output ../demo.gif

Set FontSize 17
Set Width 1000
Set Height 620
Set Padding 16
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set WindowBarSize 32

Hide
Type "clear && bash demo.sh"
Enter
Show

Wait+Screen@120s /Done: PR/
Sleep 3s
