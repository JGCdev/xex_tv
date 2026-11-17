# Changelog

## 1.0.2

- Quiet console: a channel source that fails (not live, removed, geo-blocked, an ended stream) is no longer printed
  on every retry. A channel prints one line when it ends up with nothing to play; `Config.Debug = true` prints why each
  source failed, and when a fixed screen's autoplay can't be checked yet.
- YouTube answers many hosting IPs with a sign-in page, so `ytlive:` couldn't see what a channel was airing and the
  YouTube-only channels went dark every few minutes. A channel can now end with the stream it is airing as a backup (below).
- New source for channels: `https://www.youtube.com/live/<id>`, a single live stream, checked through oEmbed (which
  works from those IPs) and skipped as soon as screens report it has ended.
- The channels that come configured are now public domain films and cartoons from the Internet Archive only: no
  broadcaster or music source ships with the resource. Add your own in `Config.Channels`; the config and the README
  show every source format (HLS, `ytlive:`, `youtube.com/live/<id>`, videos, films, video files).

## 1.0.1

- Channels no longer print one warning per source when archive.org or a broadcaster is down, rate limiting or timing
  out: the channel keeps or retries quietly (1, 2, 4, 8, then 10 minutes) and prints one line only if it has nothing
  to play. Sources that are really broken (removed, geo-blocked, not live) are printed as before, now with the HTTP code.
- Films from archive.org are remembered on the server once resolved (KVP store): channels and fixed screens start
  from the stored file while archive.org is down, and the stored answer is refreshed when it is back.
- archive.org is asked one film at a time with a short gap, and a channel stops asking it once it is down, instead of
  once per source. Fixed screens with an archive.org or stream autoplay retry when the service is down.
- A live source whose periodic check fails because of the service (not the stream) keeps playing and is checked
  again sooner, instead of switching to its backup.

## 1.0.0

- First public release, open source (MIT). Based on the TV system I have run in production on my own server.
- Free movie library in the remote: public domain films from the Internet Archive, with featured picks, search and genres. Full sync, seek and queue.
- Live TV: 15 channels configured (news, sports, music, space and nature, classic films, cartoons) from the
  broadcasters' own free streams (HLS, played with hls.js) and YouTube channels. Channel guide with categories in the
  remote, channel up / down while watching one.
- Channels run by the server: any screen tunes in at the current second. Sources have backups, live sources are
  checked every few minutes, a YouTube channel source follows the channel's current live stream, and a source that
  players can't play is skipped.
- Sound through walls: quieter from another room, much quieter from another interior or from outside (can be turned off).
- YouTube links checked on the server before they play: removed, private and non-embeddable videos get a clear message instead of an error on every screen. Titles come from YouTube.
- YouTube (videos, shorts, live and a channel's current live stream), Vimeo, and video files or live streams from hosts
  you allow. Live streams resume at the live moment after a pause.
- Server-side clock: late joiners, reconnects and bucket changes join at the right second.
- Queue with automatic next, loop, seek and per-player mute.
- Remote with play, pause, next, seek, volume, loop, resync, turn off and the channels with what each one is playing. Brand and accent colour from the config.
- Fixed screens: map props or spawned props, autoplay on boot, loop and ACE / job locks (ESX, QBCore, Qbox).
- ox_target and qb-target support, command and optional key.
- English and Spanish (ox_lib locales), including the messages shown on the screens.
- Exports: `playAtCoords`, `queue`, `stop`, `getScreen` (server) and `open` (client).
- Version check through xexstudio.com.
