import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { env } from "node:process";

const VIDEO_ID_PATTERN = /"videoId":"([A-Za-z0-9_-]{11})"/g;
const MAX_QUERY_LENGTH = 180;
const MAX_WEB_QUERY_LENGTH = 300;
const MAX_APPLICATION_NAME_LENGTH = 100;

function normalizedQuery(query: string): string {
  const value = query.replace(/\s+/g, " ").trim();
  if (!value) throw new Error("A music search query is required.");
  return value.slice(0, MAX_QUERY_LENGTH);
}

function normalizedWebQuery(query: string): string {
  const value = query.replace(/\s+/g, " ").trim();
  if (!value) throw new Error("A web search query is required.");
  return value.slice(0, MAX_WEB_QUERY_LENGTH);
}

function normalizedApplicationName(appName: string): string {
  const value = appName.replace(/\s+/g, " ").trim();
  if (!value) throw new Error("An application name is required.");
  if (value.startsWith("-") || value.includes("/")) {
    throw new Error("The application name is invalid.");
  }
  return value.slice(0, MAX_APPLICATION_NAME_LENGTH);
}

function urlFrom(raw: string): URL {
  const url = URL.parse(raw);
  if (!url) throw new Error(`Invalid internal URL: ${raw}`);
  return url;
}

async function firstYouTubeVideoID(
  query: string,
  signal?: AbortSignal,
): Promise<string | undefined> {
  const searchURL = urlFrom("https://www.youtube.com/results");
  searchURL.searchParams.set("search_query", query);
  const response = await fetch(searchURL, {
    headers: {
      "Accept-Language": "en-US,en;q=0.9",
      "User-Agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/126 Safari/537.36",
    },
    signal,
  });
  if (!response.ok)
    throw new Error(`YouTube search failed (${response.status}).`);

  const html = await response.text();
  for (const match of html.matchAll(VIDEO_ID_PATTERN)) {
    if (match[1]) return match[1];
  }
  return undefined;
}

export default function siriRemoteAssistant(pi: ExtensionAPI) {
  pi.registerTool({
    name: "play_youtube_music",
    label: "Play YouTube Music",
    description:
      "Search YouTube for a song, artist, album, playlist, genre, or music mood and open the first playable result. Use service=youtube_music unless the user explicitly asks for ordinary YouTube.",
    parameters: Type.Object({
      query: Type.String({
        description:
          "A concise music search query preserving the requested artist, song, album, genre, or mood",
        maxLength: MAX_QUERY_LENGTH,
      }),
      service: StringEnum(["youtube_music", "youtube"] as const, {
        description: "The requested YouTube surface",
      }),
    }),
    async execute(_toolCallID, params, signal) {
      const query = normalizedQuery(params.query);
      let destination: URL;
      let foundDirectResult = false;

      try {
        const videoID = await firstYouTubeVideoID(query, signal);
        if (videoID) {
          const host =
            params.service === "youtube_music"
              ? "https://music.youtube.com/watch"
              : "https://www.youtube.com/watch";
          destination = urlFrom(host);
          destination.searchParams.set("v", videoID);
          foundDirectResult = true;
        } else {
          throw new Error("No playable video result was found.");
        }
      } catch (error) {
        const host =
          params.service === "youtube_music"
            ? "https://music.youtube.com/search"
            : "https://www.youtube.com/results";
        destination = urlFrom(host);
        destination.searchParams.set(
          params.service === "youtube_music" ? "q" : "search_query",
          query,
        );
        const message = error instanceof Error ? error.message : String(error);
        console.error(
          `Direct YouTube result lookup failed; opening search: ${message}`,
        );
      }

      if (env.IREMOTE_ASSISTANT_DRY_RUN !== "1") {
        const result = await pi.exec(
          "/usr/bin/open",
          [destination.toString()],
          { signal },
        );
        if (result.code !== 0) {
          throw new Error(result.stderr.trim() || "Could not open YouTube.");
        }
      }

      const surface =
        params.service === "youtube_music" ? "YouTube Music" : "YouTube";
      const outcome = foundDirectResult
        ? `Playing “${query}” on ${surface}.`
        : `Opened ${surface} search results for “${query}”; automatic playback was unavailable.`;
      return {
        content: [{ type: "text", text: outcome }],
        details: {
          query,
          service: params.service,
          url: destination.toString(),
          foundDirectResult,
        },
      };
    },
  });

  pi.registerTool({
    name: "search_web",
    label: "Search the Web",
    description:
      "Open an encoded web search on Google or Perplexity. Use for requests to search, Google, look up, research, or answer a factual question that may benefit from current web results. Default to Google unless the user explicitly asks for Perplexity.",
    parameters: Type.Object({
      query: Type.String({
        description:
          "A concise, self-contained search query preserving names, numbers, and important context",
        maxLength: MAX_WEB_QUERY_LENGTH,
      }),
      provider: StringEnum(["google", "perplexity"] as const, {
        description: "The requested search provider; default to google",
      }),
    }),
    async execute(_toolCallID, params, signal) {
      const query = normalizedWebQuery(params.query);
      const destination = urlFrom(
        params.provider === "perplexity"
          ? "https://www.perplexity.ai/search"
          : "https://www.google.com/search",
      );
      destination.searchParams.set("q", query);
      if (env.IREMOTE_ASSISTANT_DRY_RUN !== "1") {
        const result = await pi.exec(
          "/usr/bin/open",
          [destination.toString()],
          {
            signal,
          },
        );
        if (result.code !== 0) {
          throw new Error(result.stderr.trim() || "Could not open web search.");
        }
      }
      const providerName =
        params.provider === "perplexity" ? "Perplexity" : "Google";
      return {
        content: [
          {
            type: "text",
            text: `Opened ${providerName} results for “${query}”.`,
          },
        ],
        details: {
          query,
          provider: params.provider,
          url: destination.toString(),
        },
      };
    },
  });

  pi.registerTool({
    name: "open_macos_application",
    label: "Open macOS Application",
    description:
      "Launch or bring forward an installed macOS application by its ordinary display name, such as Slack, Safari, Messages, Notes, Calendar, Spotify, or Visual Studio Code. Use this when the user asks to open, launch, start, or switch to an app.",
    parameters: Type.Object({
      app_name: Type.String({
        description:
          "The installed application's concise display name, without '.app' or extra instructions",
        maxLength: MAX_APPLICATION_NAME_LENGTH,
      }),
    }),
    async execute(_toolCallID, params, signal) {
      const appName = normalizedApplicationName(params.app_name);
      if (env.IREMOTE_ASSISTANT_DRY_RUN !== "1") {
        const result = await pi.exec("/usr/bin/open", ["-a", appName], {
          signal,
        });
        if (result.code !== 0) {
          throw new Error(
            result.stderr.trim() || `Could not find or open ${appName}.`,
          );
        }
      }
      return {
        content: [{ type: "text", text: `Opened ${appName}.` }],
        details: { appName },
      };
    },
  });
}
