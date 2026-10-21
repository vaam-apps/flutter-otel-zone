import { defineMd3Config } from "@vaam-apps/vitepress-md3/config";

// Served from GitHub Pages at /flutter-otel-zone/. The docs workflow passes
// the path Pages reports in DOCS_BASE (an empty string on pull requests, so
// `||` and not `??`), so a custom domain needs no change here.
const base = process.env.DOCS_BASE || "/flutter-otel-zone/";
const repo = "https://github.com/vaam-apps/flutter-otel-zone";

export default defineMd3Config({
  base,
  lang: "en",
  title: "otel_zone",
  titleTemplate: ":title · otel_zone",
  description:
    "One Talker, one OpenTelemetry SDK and one guarded zone for a Flutter app — with a severity floor so a phone on a metered connection is not billed for telemetry nobody reads.",
  cleanUrls: true,
  lastUpdated: true,
  // A link to a page that does not exist fails the build.
  ignoreDeadLinks: false,
  head: [["link", { rel: "icon", type: "image/svg+xml", href: `${base}logo.svg` }]],

  markdown: {
    // Dart string interpolation (`${...}`) and map literals appear in inline
    // code. VitePress compiles Markdown as Vue, so inline code is marked
    // v-pre: nothing in it is ever evaluated as an interpolation.
    config(md) {
      const render = md.renderer.rules.code_inline;
      md.renderer.rules.code_inline = (tokens, idx, options, env, self) => {
        const html = render
          ? render(tokens, idx, options, env, self)
          : `<code>${md.utils.escapeHtml(tokens[idx]?.content ?? "")}</code>`;
        return html.replace(/^<code/, "<code v-pre");
      };
    },
  },

  themeConfig: {
    md3: {
      style: "expressive",
      seed: "#f5a800",
    },

    logo: "/logo.svg",

    nav: [
      { text: "Get started", link: "/guide/getting-started", activeMatch: "^/guide/" },
      { text: "Concepts", link: "/concepts/", activeMatch: "^/concepts/" },
      { text: "Reference", link: "/reference/configuration", activeMatch: "^/reference/" },
      { text: "Platforms", link: "/platforms/", activeMatch: "^/platforms/" },
      {
        text: "More",
        items: [
          { text: "Example walkthrough", link: "/guide/example" },
          { text: "Development", link: "/development/" },
          { text: "Crash harness", link: "/development/crash-harness" },
          { text: "Changelog", link: `${repo}/blob/main/CHANGELOG.md` },
          { text: "All vaam-apps docs", link: "https://vaam-apps.github.io/vitepress-md3/projects/" },
        ],
      },
    ],

    sidebar: [
      {
        text: "Introduction",
        items: [
          { text: "Overview", link: "/" },
          { text: "Getting started", link: "/guide/getting-started" },
          { text: "Example walkthrough", link: "/guide/example" },
        ],
      },
      {
        text: "Concepts",
        items: [
          { text: "How it fits together", link: "/concepts/" },
          { text: "The guarded zone", link: "/concepts/guarded-zone" },
          { text: "The export floor", link: "/concepts/export-floor" },
          { text: "Telemetry never blocks the app", link: "/concepts/never-blocks" },
        ],
      },
      {
        text: "Guides",
        items: [
          { text: "Scrubbing with redact", link: "/guide/redaction" },
          { text: "Linking to an account", link: "/guide/end-user" },
          { text: "The offline spool", link: "/guide/spool" },
          { text: "Native crashes", link: "/guide/native-crashes" },
          { text: "Which screen it died on", link: "/guide/crash-screen" },
          { text: "Testing against it", link: "/guide/testing" },
        ],
      },
      {
        text: "Platforms",
        items: [
          { text: "Support and the Pigeon channel", link: "/platforms/" },
          { text: "Android", link: "/platforms/android" },
          { text: "iOS", link: "/platforms/ios" },
          { text: "Web and desktop", link: "/platforms/web-desktop" },
        ],
      },
      {
        text: "Reference",
        items: [
          { text: "Configuration", link: "/reference/configuration" },
          { text: "API overview", link: "/reference/api" },
          { text: "What reaches the collector", link: "/reference/telemetry" },
        ],
      },
      {
        text: "Development",
        items: [
          { text: "Building and testing", link: "/development/" },
          { text: "Crash harness", link: "/development/crash-harness" },
          { text: "Changelog", link: `${repo}/blob/main/CHANGELOG.md` },
        ],
      },
    ],

    outline: { level: [2, 3] },
    search: { provider: "local" },
    socialLinks: [{ icon: "github", link: repo }],
    editLink: {
      pattern: `${repo}/edit/main/docs/:path`,
      text: "Edit this page on GitHub",
    },
    footer: {
      message: "Released under the MIT License.",
    },
  },
});
