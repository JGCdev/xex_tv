// Screen player: one per screen, in its own DUI. Follows the state the client script sends.
(() => {
    "use strict";

    const elements = {
        idle: document.getElementById("idle"),
        idleBrand: document.getElementById("idle-brand"),
        idleText: document.getElementById("idle-text"),
        loading: document.getElementById("loading"),
        loadingBrand: document.getElementById("loading-brand"),
        loadingDetail: document.getElementById("loading-detail"),
        youtubeSlot: document.getElementById("youtube-slot"),
        vimeoSlot: document.getElementById("vimeo-slot"),
        video: document.getElementById("html-video"),
        error: document.getElementById("error"),
        errorTitle: document.getElementById("error-title"),
        errorDetail: document.getElementById("error-detail"),
        errorCode: document.getElementById("error-code"),
    };

    const state = {
        screenId: null,
        mediaToken: null,
        media: null,
        mediaKey: null,
        loadId: 0,
        playing: false,
        resumed: false,
        live: false,
        volume: 0,
        driftTolerance: 3,
        youtube: null,
        youtubeReady: false,
        vimeo: null,
        vimeoReady: false,
        hls: null,
        targetTime: 0,
        reported: false,
    };

    // English fallbacks; the client sends the server's language on load.
    let texts = {
        player_waiting: "Waiting for content",
        player_loading: "Loading",
        player_failed: "Can't play this",
        player_no_detail: "No details available.",
        player_code: "Code: %s",
        player_yt_2: "Invalid YouTube video id. Check the link.",
        player_yt_5: "YouTube couldn't start this video in the game browser.",
        player_yt_100: "The video was removed, is private or doesn't exist.",
        player_yt_101: "The owner doesn't allow this video to play outside YouTube.",
        player_yt_153: "YouTube blocked playback in the game browser.",
        player_yt_other: "YouTube couldn't play this video.",
        player_api_failed: "The video player couldn't be downloaded. Check the connection.",
        player_direct_failed: "The file doesn't exist, the format isn't supported or the host refused the connection.",
        player_stream_failed: "This broadcast isn't answering. It may be off air or not available in your country.",
        player_vimeo_failed: "Vimeo couldn't play this video. Its owner may only allow it on some websites.",
        player_autoplay: "The game browser blocked autoplay.",
        player_unsupported: "Source not supported by this player.",
        kind_youtube: "YouTube",
        kind_vimeo: "Vimeo",
        kind_archive: "Internet Archive",
        kind_direct: "Video",
        kind_hls: "Live TV",
    };

    const t = (key) => texts[key] || key;

    function applyUi(ui) {
        if (!ui) return;
        const brand = [ui.brand, ui.title].filter(Boolean).join(" ");
        elements.idleBrand.textContent = brand;
        elements.loadingBrand.textContent = brand;

        const hex = String(ui.accent || "").replace("#", "");
        if (hex.length === 6) {
            const [r, g, b] = [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16));
            document.documentElement.style.setProperty("--accent", `#${hex}`);
            document.documentElement.style.setProperty("--accent-glow", `rgba(${r}, ${g}, ${b}, 0.14)`);
        }
    }

    function applyTexts(next) {
        if (next && typeof next === "object") texts = { ...texts, ...next };
        elements.idleText.textContent = t("player_waiting");
        elements.errorTitle.textContent = t("player_failed");
    }

    function setVisible(target) {
        for (const key of ["idle", "loading", "youtubeSlot", "vimeoSlot", "video", "error"]) {
            elements[key].classList.toggle("hidden", elements[key] !== target);
        }
    }

    function showLoading(kind) {
        elements.loadingDetail.textContent = `${t("player_loading")} · ${t(`kind_${kind}`)}`;
        setVisible(elements.loading);
    }

    function showError(detail, code) {
        elements.errorTitle.textContent = t("player_failed");
        elements.errorDetail.textContent = detail || t("player_no_detail");
        elements.errorCode.textContent = t("player_code").replace("%s", code || "UNKNOWN");
        setVisible(elements.error);
        report("error", { code: code || "UNKNOWN", detail: elements.errorDetail.textContent });
    }

    function report(event, payload = {}) {
        if (typeof GetParentResourceName !== "function") return;
        fetch(`https://${GetParentResourceName()}/playerEvent`, {
            method: "POST",
            headers: { "Content-Type": "application/json; charset=UTF-8" },
            body: JSON.stringify({ event, screenId: state.screenId, mediaToken: state.mediaToken, ...payload }),
        }).catch(() => {});
    }

    // Duration, title and whether it is live go to the server once per media, so it can run the queue.
    function reportMedia(duration, title, live) {
        if (state.reported) return;
        state.reported = true;
        report("media", {
            duration: !live && Number.isFinite(duration) && duration > 0 ? duration : null,
            title: title || null,
            live: !!live,
        });
    }

    function mediaKey(media) {
        if (!media) return "";
        return `${media.kind}:${media.id || media.url || ""}`;
    }

    function resetMedia() {
        state.loadId += 1;
        if (state.youtube) {
            try {
                state.youtube.destroy();
            } catch (_) {}
        }
        state.youtube = null;
        state.youtubeReady = false;
        elements.youtubeSlot.replaceChildren();

        if (state.vimeo) state.vimeo.destroy().catch(() => {});
        state.vimeo = null;
        state.vimeoReady = false;
        elements.vimeoSlot.replaceChildren();

        if (state.hls) state.hls.destroy();
        state.hls = null;

        const video = elements.video;
        video.onloadedmetadata = null;
        video.oncanplay = null;
        video.onerror = null;
        video.pause();
        video.removeAttribute("src");
        video.load();

        state.targetTime = 0;
        state.live = false;
        state.media = null;
        state.mediaKey = null;
        state.reported = false;
    }

    function loadScript(src, globalReady, promiseKey, callbackName) {
        if (globalReady()) return Promise.resolve();
        if (state[promiseKey]) return state[promiseKey];

        state[promiseKey] = new Promise((resolve, reject) => {
            const timeout = window.setTimeout(() => reject(new Error("API_TIMEOUT")), 15000);
            const done = () => {
                window.clearTimeout(timeout);
                resolve();
            };

            if (callbackName) {
                const previous = window[callbackName];
                window[callbackName] = () => {
                    if (typeof previous === "function") previous();
                    done();
                };
            }

            const script = document.createElement("script");
            script.src = src;
            script.async = true;
            if (!callbackName) script.onload = done;
            script.onerror = () => {
                window.clearTimeout(timeout);
                state[promiseKey] = null;
                reject(new Error("API_LOAD_FAILED"));
            };
            document.head.appendChild(script);
        });
        return state[promiseKey];
    }

    // Each load gets a number: async work of a load that was replaced since then stops there.
    const isCurrent = (loadId) => loadId === state.loadId;

    // YOUTUBE -------------------------------------------------------------------------------------

    const youtubeErrors = { 2: "player_yt_2", 5: "player_yt_5", 100: "player_yt_100", 101: "player_yt_101", 150: "player_yt_101", 153: "player_yt_153" };

    function applyYouTubePlayback() {
        if (!state.youtube || !state.youtubeReady) return;
        try {
            const player = state.youtube;
            player.setVolume(state.volume);
            if (state.volume > 0 && player.isMuted()) player.unMute();

            if (state.live) {
                // Back from a pause: everyone watches the live edge, not where this screen stopped.
                if (state.resumed) player.seekTo(Number(player.getDuration()) || 0, true);
            } else {
                const actual = Number(player.getCurrentTime()) || 0;
                if (Math.abs(actual - state.targetTime) > state.driftTolerance) player.seekTo(state.targetTime, true);
            }

            if (state.playing) player.playVideo();
            else player.pauseVideo();
        } catch (error) {
            report("warning", { code: "YT_CONTROL", detail: String(error) });
        }
    }

    async function loadYouTube(media, loadId) {
        showLoading("youtube");

        try {
            await loadScript("https://www.youtube.com/iframe_api", () => window.YT && window.YT.Player, "youtubeApiPromise", "onYouTubeIframeAPIReady");
            if (!isCurrent(loadId)) return;

            const playerVars = {
                autoplay: 1,
                controls: 0,
                disablekb: 1,
                enablejsapi: 1,
                fs: 0,
                iv_load_policy: 3,
                modestbranding: 1,
                origin: window.location.origin,
                playsinline: 1,
                rel: 0,
            };
            if (!state.live) playerVars.start = Math.max(0, Math.floor(state.targetTime || 0));

            const node = document.createElement("div");
            node.id = `youtube-player-${Date.now()}`;
            elements.youtubeSlot.replaceChildren(node);

            state.youtube = new window.YT.Player(node.id, {
                host: "https://www.youtube-nocookie.com",
                width: "100%",
                height: "100%",
                videoId: media.id,
                playerVars,
                events: {
                    onReady: () => {
                        if (!isCurrent(loadId)) return;
                        state.youtubeReady = true;
                        setVisible(elements.youtubeSlot);
                        applyYouTubePlayback();
                        report("ready", { provider: "youtube" });
                    },
                    onStateChange: (event) => {
                        if (!isCurrent(loadId) || event.data !== 1 || state.reported) return;
                        try {
                            const data = state.youtube.getVideoData() || {};
                            // A live stream from the config that has ended plays as a recording: report it, so
                            // the channel moves on to its next source.
                            if (media.live && data.isLive === false) {
                                state.youtube.stopVideo();
                                showError(t("player_stream_failed"), "YT_LIVE_ENDED");
                                return;
                            }
                            // Live streams report a growing duration: never send it, or the queue would cut them.
                            if (data.isLive) state.live = true;
                            reportMedia(Number(state.youtube.getDuration()), data.title, state.live);
                        } catch (_) {
                            reportMedia(null, null, state.live);
                        }
                    },
                    onError: (event) => {
                        if (isCurrent(loadId)) showError(t(youtubeErrors[event.data] || "player_yt_other"), `YOUTUBE_${event.data}`);
                    },
                },
            });
        } catch (error) {
            if (isCurrent(loadId)) showError(t("player_api_failed"), `YT_${error && error.message ? error.message : "API"}`);
        }
    }

    // VIMEO ---------------------------------------------------------------------------------------

    async function applyVimeoPlayback() {
        const player = state.vimeo;
        if (!player || !state.vimeoReady) return;
        try {
            await player.setVolume(state.volume / 100);
            const actual = Number(await player.getCurrentTime()) || 0;
            if (Math.abs(actual - state.targetTime) > state.driftTolerance) await player.setCurrentTime(state.targetTime);
            if (state.vimeo !== player) return;
            if (state.playing) await player.play();
            else await player.pause();
        } catch (error) {
            report("warning", { code: "VIMEO_CONTROL", detail: String(error && error.name ? error.name : error) });
        }
    }

    async function loadVimeo(media, loadId) {
        showLoading("vimeo");

        try {
            await loadScript("https://player.vimeo.com/api/player.js", () => window.Vimeo && window.Vimeo.Player, "vimeoApiPromise");
            if (!isCurrent(loadId)) return;

            const node = document.createElement("div");
            node.className = "embed-host";
            elements.vimeoSlot.replaceChildren(node);

            const options = {
                autoplay: true,
                controls: false,
                title: false,
                byline: false,
                portrait: false,
                keyboard: false,
                pip: false,
                dnt: true,
                playsinline: true,
            };
            // Unlisted videos need their hash.
            if (media.hash) options.url = `https://vimeo.com/${media.id}/${media.hash}`;
            else options.id = Number(media.id);

            const player = new window.Vimeo.Player(node, options);
            state.vimeo = player;

            player.on("play", () => {
                if (state.vimeo !== player || state.reported) return;
                Promise.all([player.getDuration(), player.getVideoTitle()])
                    .then(([duration, title]) => reportMedia(Number(duration), title, false))
                    .catch(() => reportMedia(null, null, false));
            });
            player.on("error", (error) => {
                if (state.vimeo === player) showError(t("player_vimeo_failed"), `VIMEO_${error && error.name ? error.name : "ERROR"}`);
            });

            await player.ready();
            if (state.vimeo !== player) return;
            state.vimeoReady = true;
            setVisible(elements.vimeoSlot);
            applyVimeoPlayback();
            report("ready", { provider: "vimeo" });
        } catch (error) {
            if (!isCurrent(loadId)) return;
            const name = error && (error.name || error.message);
            if (name === "API_LOAD_FAILED" || name === "API_TIMEOUT") showError(t("player_api_failed"), `VIMEO_${name}`);
            else showError(t("player_vimeo_failed"), `VIMEO_${name || "ERROR"}`);
        }
    }

    // VIDEO FILES AND LIVE STREAMS ----------------------------------------------------------------

    // Live: no clock to follow, every screen plays from the live edge.
    function liveEdge() {
        const video = elements.video;
        if (state.hls && Number.isFinite(state.hls.liveSyncPosition)) return state.hls.liveSyncPosition;
        return video.seekable.length ? video.seekable.end(video.seekable.length - 1) : null;
    }

    function applyVideoPlayback() {
        const video = elements.video;
        video.volume = Math.max(0, Math.min(1, state.volume / 100));

        if (state.live) {
            const edge = liveEdge();
            if (state.resumed && edge !== null) video.currentTime = edge;
        } else if (Math.abs((video.currentTime || 0) - state.targetTime) > state.driftTolerance) {
            video.currentTime = state.targetTime;
        }

        if (state.playing) {
            video.play().catch((error) => {
                if (error && error.name === "NotAllowedError") showError(t("player_autoplay"), "AUTOPLAY_BLOCKED");
            });
        } else {
            video.pause();
        }
    }

    function prepareVideo(media, loadId, failedKey, codePrefix) {
        const video = elements.video;
        video.volume = Math.max(0, Math.min(1, state.volume / 100));

        video.onloadedmetadata = () => {
            if (!isCurrent(loadId)) return;
            if (!Number.isFinite(video.duration)) state.live = true;
            if (!state.live && state.targetTime > 0) video.currentTime = state.targetTime;
            // HLS reports from its own playlist events, which know better.
            if (!state.hls) reportMedia(Number(video.duration), null, state.live);
        };

        video.oncanplay = () => {
            video.oncanplay = null;
            if (!isCurrent(loadId)) return;
            setVisible(video);
            state.resumed = false;
            applyVideoPlayback();
            report("ready", { provider: media.kind });
        };

        video.onerror = () => {
            if (!isCurrent(loadId) || state.hls) return;
            showError(t(failedKey), `${codePrefix}_${video.error ? video.error.code : "UNKNOWN"}`);
        };
    }

    function loadDirect(media, loadId) {
        showLoading(media.kind);
        prepareVideo(media, loadId, "player_direct_failed", "HTML5");
        elements.video.src = media.url;
        elements.video.load();
    }

    async function loadHls(media, loadId) {
        showLoading("hls");
        prepareVideo(media, loadId, "player_stream_failed", "HLS_NATIVE");

        try {
            await loadScript("vendor/hls.min.js", () => !!window.Hls, "hlsLibPromise");
        } catch (_) {
            // Without hls.js the browser may still play HLS on its own.
        }
        if (!isCurrent(loadId)) return;

        const Hls = window.Hls;
        const video = elements.video;
        if (!Hls || !Hls.isSupported()) {
            if (video.canPlayType("application/vnd.apple.mpegurl")) {
                video.src = media.url;
                video.load();
            } else {
                showError(t("player_unsupported"), "HLS_UNSUPPORTED");
            }
            return;
        }

        const hls = new Hls({
            liveDurationInfinity: true,
            backBufferLength: 30,
            maxBufferLength: 30,
            // The screen is 1280x720: higher qualities would only cost every player bandwidth.
            capLevelToPlayerSize: true,
            // A TV in the game shows the picture, without subtitles or closed captions.
            subtitleDisplay: false,
            enableCEA708Captions: false,
        });
        state.hls = hls;
        let started = false;
        let lastRecovery = 0;
        video.addEventListener("playing", () => (started = true), { once: true });

        hls.on(Hls.Events.LEVEL_LOADED, (_, data) => {
            if (state.hls !== hls || state.reported || !data.details) return;
            state.live = !!data.details.live;
            reportMedia(data.details.totalduration, null, state.live);
            if (!state.live && state.targetTime > 0) video.currentTime = state.targetTime;
        });

        hls.on(Hls.Events.ERROR, (_, data) => {
            if (state.hls !== hls || !data.fatal) return;
            // A stream that never started is down. One that was playing gets a recovery attempt every 30 s.
            const now = Date.now();
            if (started && now - lastRecovery > 30000) {
                lastRecovery = now;
                if (data.type === Hls.ErrorTypes.MEDIA_ERROR) return hls.recoverMediaError();
                if (data.type === Hls.ErrorTypes.NETWORK_ERROR) return hls.startLoad();
            }
            showError(t("player_stream_failed"), `HLS_${data.details || data.type}`);
            hls.destroy();
            if (state.hls === hls) state.hls = null;
        });

        hls.loadSource(media.url);
        hls.attachMedia(video);
    }

    // STATE ---------------------------------------------------------------------------------------

    function readMessage(message) {
        const wasPlaying = state.playing;
        state.screenId = message.screenId || state.screenId;
        state.mediaToken = message.mediaToken || state.mediaToken;
        state.playing = message.playing !== false;
        state.resumed = state.playing && !wasPlaying;
        state.volume = Math.max(0, Math.min(100, Number(message.volume) || 0));
        state.targetTime = Math.max(0, Number(message.currentTime) || 0);
        if (Number(message.driftTolerance) > 0) state.driftTolerance = Number(message.driftTolerance);
    }

    function loadMedia(message) {
        const media = message.media;
        resetMedia();
        readMessage(message);

        if (!media || !media.kind) {
            setVisible(elements.idle);
            return;
        }

        state.media = media;
        state.mediaKey = mediaKey(media);
        state.live = media.live === true;
        const loadId = state.loadId;

        switch (media.kind) {
            case "youtube":
                loadYouTube(media, loadId);
                break;
            case "vimeo":
                loadVimeo(media, loadId);
                break;
            case "hls":
                loadHls(media, loadId);
                break;
            case "direct":
            case "archive":
                loadDirect(media, loadId);
                break;
            default:
                showError(t("player_unsupported"), "UNSUPPORTED_SOURCE");
        }
    }

    function syncMedia(message) {
        // New media (a queued repeat of the same link also gets a new token): load it again.
        if (!message.media || mediaKey(message.media) !== state.mediaKey || message.mediaToken !== state.mediaToken) {
            loadMedia(message);
            return;
        }

        readMessage(message);
        if (message.media.live) state.live = true;

        const kind = state.media.kind;
        if (kind === "youtube") applyYouTubePlayback();
        else if (kind === "vimeo") applyVimeoPlayback();
        else if (kind === "direct" || kind === "archive" || kind === "hls") applyVideoPlayback();
        state.resumed = false;
    }

    window.addEventListener("message", (event) => {
        const message = event.data;
        if (!message || typeof message !== "object") return;

        if (message.ui) applyUi(message.ui);
        if (message.texts) applyTexts(message.texts);

        if (message.action === "load") {
            loadMedia(message);
        } else if (message.action === "sync") {
            syncMedia(message);
        }
    });

    window.addEventListener("error", (event) => {
        report("warning", { code: "WINDOW_ERROR", detail: event.message || "Unknown JavaScript error" });
    });

    applyTexts();
    report("boot", { origin: window.location.origin, referrer: document.referrer });
})();
