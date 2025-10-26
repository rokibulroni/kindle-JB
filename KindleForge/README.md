# KindleForge 📦

> [!NOTE]
> Welcome To KindleForge 4!

<a href='https://ko-fi.com/W7W31J9IS0' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi5.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>

*Like my work? Consider donating or just starring my repo! :)*

KindleForge is a GUI Appstore for Kindles, allowing you to download & install tweaks & applications such as KOReader directly on-device, without having to keep copying files locally.

## Installation

> [!CAUTION]
> Ensure you are on the latest hotfix prior to installation! Older hotfixes could potentially cause bricks! As always, jailbreak at your own risk ;)

1. Grab the lastest file from releases
2. Unzip it, paste both `KindleForge/` and `KindleForge.sh` into the `documents/` folder on your Kindle.
3. Run the scriptlet, and have fun!

## Features

- Reliable installation flow
- Smooth scroll, pretty frontend & UI
- Multiple packages
- Hard-float and soft-float support
- Active community & support

<img width="536" height="724" alt="UI" src="https://github.com/user-attachments/assets/a619e79d-b436-49e2-a52e-85bcd085f7c8" />

## Minimum Requirements

- AdBreak, WinterBreak, or LanguageBreak
- Latest Universal Hotfix
- Above the 5.13.7 firmware (at present - to be lowered)
- Both **hard-float and soft-float** kindles should work, but not all packages may support both architectures.

## Troubleshooting

Try reloading multiple times, rebooting, or re-copying assets from the latest release and trying again.

KindleTweaks project suggestions? Tweak suggestions? Feature requests? Check out our [discord](https://discord.gg/aSG3eMsAsW)

### Hotfix

Reinstallation steps:

1. Turn on aeroplane mode
2. Restore OTAs
3. Download latest hotfix from wiki, copy to kindle root
4. Update your kindle 
5. Run the hotfix
6. Rename OTAs
7. You can use WiFi once more

### KindleForge

**Q: The KindleForge scriptlet doesn't appear!**

A: Ensure you have copied `KindleForge.sh` into your documents folder. If this is true, and the scriptlet still isn't showing, then reinstall the latest hotfix using the steps above.

**Q: When I click on the scriptlet, it says "Application Error!"**

A: Chances are, you've installed KindleForge incorrectly. **BOTH the folder AND scriptlet MUST be in the `documents` folder on your kindle!** 

**Q: I keep getting core dumps & crashlogs generated when using KindleForge/Scriptlets!**

A: You must be on the latest hotfix, 2.3.1+. Use the steps mentioned above to reinstall hotfix

**Q: No apps load and I'm getting "Unknown ABI!"**

A: This happens commonly after you fix the core dump issue, please use the "Update KForge" functionality in-app to resolve. 

If this doesn't work:

1. Remove:
   -  documents/KindleForge.sh
   -  documents/KindleForge
2. Reboot
3. Re-install with the above steps.

**Q: App is installing/uninstalling forever!**

A: Could be caused by a multitude of issues such as beginning the install without wifi, DNS stuff. You can press "refresh packages" in the top bar to clear the lock and retry, or reboot.

## Special Thanks

- [Kurizu](https://ko-fi.com/kurizu), Illusion help & app image
- Gingrspacecadet, KFPM, inspiration & repository help
- Clint, event & KFPM troubleshooting, scroll help
- Dammit Jeff, Gambatte-K2 & KOReader icons
- ThatPotatoDev, ABI differentiation, dependencies, & tweak support
