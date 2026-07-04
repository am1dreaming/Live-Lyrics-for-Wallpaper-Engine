// MinenkoY
(function () {
  const coverSvg = `
    <svg xmlns="http://www.w3.org/2000/svg" width="640" height="640" viewBox="0 0 640 640">
      <defs>
        <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%"  stop-color="#c9384f"/>
          <stop offset="55%" stop-color="#5b1b3a"/>
          <stop offset="100%" stop-color="#140a1f"/>
        </linearGradient>
      </defs>
      <rect width="640" height="640" fill="url(#g)"/>
      <circle cx="470" cy="170" r="170" fill="#ffffff" opacity="0.05"/>
      <circle cx="150" cy="500" r="130" fill="#ff9bb0" opacity="0.10"/>
      <text x="50%" y="52%" font-family="Segoe UI, sans-serif" font-size="150"
            font-weight="800" fill="#ffffff" opacity="0.9"
            text-anchor="middle" dominant-baseline="middle">MJ</text>
    </svg>`;
  const coverUrl =
    "data:image/svg+xml;charset=utf-8," + encodeURIComponent(coverSvg.trim());

  const raw = [
    [1.2,  "This woman that I know"],
    [4.6,  "She came to me one day"],
    [8.0,  "Said she needed my love"],
    [11.4, "And she wanted me to stay"],
    [14.9, "So I gave her all I had"],
    [18.3, "Inside I felt so proud"],
    [21.8, "But she took me for a ride"],
    [25.2, "Now I feel so low"],
    [28.7, "(she was livin' a lie)", true],
    [31.6, "Should've known better"],
    [35.0, "But I fell for the game"],
    [38.5, "Ooh, she was from Chicago"],
    [42.4, "And I still feel the flame"],
    [46.0, "How could I be so blind"],
    [49.5, "To a love that was untrue"],
    [53.0, "Chicago, oh, Chicago"],
  ];

  const LOOP_MS = 57000;

  const lines = raw.map((r, i) => {
    const startMs = Math.round(r[0] * 1000);
    const endMs = i < raw.length - 1
      ? Math.round(raw[i + 1][0] * 1000)
      : LOOP_MS;
    return {
      startMs,
      endMs,
      text: r[1],
      isBackground: !!r[2],
      words: [],
    };
  });

  window.MOCK_DATA = {
    __loopMs: LOOP_MS,
    track: {
      title: "Chicago",
      artist: "Michael Jackson",
      coverUrl,
      durationMs: LOOP_MS,
    },
    position: 0,
    isPlaying: true,
    timestamp: Date.now(),
    lyrics: {
      type: "line",
      lines,
    },
  };
})();
