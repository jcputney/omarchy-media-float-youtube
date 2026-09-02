# YouTube Float

Browse YouTube and play a video in a small window that floats above everything
and follows you from workspace to workspace. Made for
[Omarchy](https://omarchy.org/).

Watch Later and anything you left partway through come first, then your
subscriptions, your playlists, your channels, and search.

## Install

```bash
omarchy plugin add https://github.com/jcputney/omarchy-media-float-youtube.git --enable
~/.config/omarchy/plugins/io.github.jcputney.media-float-youtube/setup
omarchy restart shell
```

The plugin and the command are separate halves, so there are two installers.
`omarchy plugin add` hands the shell the picker overlay. `setup` installs the
`youtube-float` command, the window rules, and checks you have mpv and yt-dlp.

The restart is the third line because the shell caches plugin QML once it has
loaded it — without it, the picker you just installed stays dark.

`setup --check` reports what is installed. `setup --uninstall` takes back
everything it wrote.

## Sign in

Search and channel browsing work signed out. Your subscriptions, Watch Later,
history and playlists need cookies:

```bash
youtube-float auth
```

That prints the steps and tells you whether the cookies you have still work.

Cookies, not OAuth, because YouTube's Data API has had no route to your
recommendations, Watch Later or watch history since 2016. There is no OAuth
scope to ask for. Export cookies from a browser profile you are signed into,
save them as Netscape-format `~/.config/youtube-float/cookies.txt` (mode 0600),
and check them with `youtube-float auth`.

One thing worth knowing: YouTube invalidates cookies exported from a browser
profile that is still actively signed in and being used. Export from a profile
you then leave alone — a dedicated one works best.

## Use it

```bash
youtube-float browse            # continue watching, subscriptions, search
youtube-float play <id|url>     # play one video
youtube-float quality toggle    # 720p <-> best, restarts the video
```

Add keybindings to `~/.config/hypr/bindings.lua` — `setup` prints these rather
than editing the file, because which keys are free is your business:

```lua
o.bind("SUPER + ALT + Y", "YouTube: browse and play", "youtube-float browse")
o.bind("SUPER + ALT + SHIFT + Y", "YouTube: toggle video quality", "youtube-float quality toggle")
o.bind("SUPER + ALT + SHIFT + P", "Overlay: hide/show", "float-overlay toggle")
o.bind("SUPER + ALT + CTRL + P", "Overlay: close", "float-overlay quit")
o.bind("SUPER + ALT + O", "Overlay: cycle size", "float-overlay size cycle")
```

`float-overlay` drives whichever overlay is up, so the same three control keys
work for the Plex and Twitch tools too.

While something is playing: `SUPER` + right-drag resizes the window freehand,
`SUPER + ALT + O` cycles it through four preset sizes, and the screen will not
blank or lock.

## Requirements

`mpv`, `yt-dlp`, `jq`, `curl`, `hyprctl`, `socat`.

`fzf`, `chafa` and `ghostty` are optional. They are the fallback menu, used when
the shell plugin is disabled or you are not on Omarchy — the whole tool works
without the plugin, just in a terminal window instead of a native overlay.

## Related

- [omarchy-media-float-plex](https://github.com/jcputney/omarchy-media-float-plex)
- [omarchy-media-float-twitch](https://github.com/jcputney/omarchy-media-float-twitch)

Install any one of them on its own. Installed together they share the player
window, the overlay controls and the Hyprland rules.

## Licence

MIT.
