## Single Host erGW, PGW and SGSEMU Test Setup

This walk-through creates a combined GGSN/PGW consisting of an erGW instance as
Control Plane Function (CPF), a VPP instance as User Plane Function (UPF) and
a sgsnemu(lator) from the OpenGGSN project as test driver.

### Requirements

* Ubuntu 18.04 Linux system (bare metal or VM)

### Network Layout


TBD:

### Setup


The doc/ergw-vpp-sgnemu.sh script will create the network layout as shown in
the picture under "Setup".

_____________________________________________________________________________________
**Note**: the source directories in the next steps are referenced in automatic startup
	  in doc/pgw-dev/ergw-vpp-sgnemu.sh, if you change them you have to make sure you also
	  adjust that script and all it's helpers in doc/tmux/.
_____________________________________________________________________________________

1. Install rebar
2. Install tmux and sgsnemu with ```sudo apt install -yy tmux openggsn```
2. Checkout and build erGW under /usr/src/erlang/ergw
3. Checkout and build VPP under /usr/src/vpp  
     If everything is build properly, erGW and VPP can be started with ```doc/pgw-dev/ergw-vpp-sgnemu.sh```.
