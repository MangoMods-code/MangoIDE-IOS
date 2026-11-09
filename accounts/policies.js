// Public pages Stripe (and customers) look for: what MangoIDE is, prices, terms, privacy and refunds.
// Set BUSINESS_NAME and CONTACT_EMAIL on the accounts service to fill in your details.

module.exports = function policies({ html, PRO_PRICE_CENTS, TOPUPS, AI_MARKUP }) {
  const esc = (t) => String(t).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const NAME = esc(process.env.BUSINESS_NAME || "MangoMods");
  const EMAIL = process.env.CONTACT_EMAIL ? esc(process.env.CONTACT_EMAIL) : "";
  const contact = EMAIL
    ? `email <a href="mailto:${EMAIL}">${EMAIL}</a>`
    : `message <a href="https://t.me/MangoOwnah">@MangoOwnah on Telegram</a>`;
  const money = (cents) => `$${(cents / 100).toFixed(2)}`;
  const UPDATED = "November 9, 2026";

  const pages = {
    terms: ["Terms of Service", `
<h1>Terms of Service</h1><p class="muted">Last updated ${UPDATED}</p>
<p>MangoIDE is a code editor for iPhone and iPad made by ${NAME}. By using MangoIDE or buying MangoIDE Pro or AI credit, you agree to these terms.</p>
<h2>Your account</h2>
<p>You sign in with GitHub. Keep your GitHub account secure; you're responsible for what happens under your account. You can sign out of every device from Settings › Account.</p>
<h2>Your code</h2>
<p>Your projects are yours. We don't claim any rights to them. Features like cloud sync, share links and live sessions store or send your files only so the feature can work.</p>
<h2>MangoIDE Pro</h2>
<p>Pro is a monthly subscription (${money(PRO_PRICE_CENTS)} a month unless shown otherwise at checkout) that renews automatically until you cancel. Cancel anytime from Settings › MangoIDE Pro › Manage or Cancel Subscription; you keep Pro until the end of the period you paid for.</p>
<h2>AI credit</h2>
<p>AI credit is prepaid balance for the coding agent. It's used up as the agent works, at the provider's cost plus a ${Math.round((AI_MARKUP - 1) * 100)}% service fee. Credit has no cash value, can't be transferred and doesn't expire while the service runs.</p>
<h2>Acceptable use</h2>
<p>Don't use MangoIDE's servers (code runner, cloud, sharing, live sessions or the agent) to break the law, attack other systems, mine cryptocurrency, send spam, or share content you don't have the right to share. We may suspend accounts that do.</p>
<h2>Availability</h2>
<p>We work to keep everything running but can't promise the online features will always be available or error-free. Keep your own copies of important work. MangoIDE is provided "as is", and to the extent the law allows, ${NAME} isn't liable for indirect or lost-data damages; our total liability is limited to what you paid us in the last 3 months.</p>
<h2>Changes</h2>
<p>We may update these terms; the date above changes when we do. Continuing to use MangoIDE means you accept the update.</p>
<h2>Contact</h2><p>Questions? ${contact}.</p>`],

    privacy: ["Privacy Policy", `
<h1>Privacy Policy</h1><p class="muted">Last updated ${UPDATED}</p>
<p>${NAME} runs MangoIDE. This page explains what we keep and why. We don't sell your data and we don't show ads.</p>
<h2>What we keep</h2>
<ul>
<li><b>Your GitHub profile</b>: username, display name and picture, from signing in.</li>
<li><b>GitHub access</b>: stored encrypted on our server and used only for the GitHub features you use (listing, cloning, pulling and pushing your repositories).</li>
<li><b>Purchases</b>: whether you have Pro, your AI credit balance and its history. Card details are handled by Stripe and never reach us.</li>
<li><b>Sign-in sessions</b>: which devices are signed in and when they were last used, so you can sign out everywhere.</li>
<li><b>Files you choose to put online</b>: cloud sync backups (only if you turn it on), share links you create, and files in live sessions while they run.</li>
</ul>
<h2>What stays on your device</h2>
<p>Your projects (unless you turn on cloud sync), your own Anthropic API key and your runner key are kept on your device. Your sign-in token is kept in the device's Keychain.</p>
<h2>Services we use</h2>
<p>Stripe (payments), GitHub (sign-in and repositories), Railway (our servers) and Anthropic (the AI agent, when you use AI credit: the code and messages the agent works with are sent to Anthropic to answer).</p>
<h2>Deleting your data</h2>
<p>Delete projects from the cloud in Settings › Cloud Sync & Backup, turn off share links in Settings › Sharing & Live Sessions, and to delete your whole account, ${contact}.</p>
<h2>Contact</h2><p>${contact[0].toUpperCase() + contact.slice(1)}.</p>`],

    refunds: ["Refund Policy", `
<h1>Refund Policy</h1><p class="muted">Last updated ${UPDATED}</p>
<div class="card"><b>Short version:</b> cancel Pro anytime. If something went wrong with a purchase, ask within 14 days and we'll make it right.</div>
<h2>MangoIDE Pro</h2>
<p>You can cancel anytime in Settings › MangoIDE Pro › Manage or Cancel Subscription. You keep Pro until the end of the month you paid for, and you won't be charged again. If you were charged by mistake or Pro didn't work for you, ask within 14 days of the charge for a refund.</p>
<h2>AI credit</h2>
<p>Unused AI credit can be refunded within 14 days of buying it. Credit that's already been used by the agent can't be refunded. Refunds go back to the card you paid with; Stripe usually shows them within 5–10 business days.</p>
<h2>How to ask</h2>
<p>Use <b>Receipts & Refunds</b> in Settings › AI Credit to see your receipts, then ${contact} with the receipt number.</p>`],
  };

  function page(res, key) {
    const [title, body] = pages[key];
    html(res, `${title} · MangoIDE`, body);
  }

  function home(res) {
    const top = TOPUPS.map(money).join(", ");
    html(res, "MangoIDE", `
<h1>🥭 MangoIDE</h1>
<p>A full code editor for iPhone and iPad: tabs, split view, 90+ languages, running code, a coding agent, GitHub, cloud sync and live collaboration. Most of it is free.</p>
<div class="card"><b>MangoIDE Pro</b> · ${money(PRO_PRICE_CENTS)} a month<br>Cloud sync & backup, clone any GitHub repo, commit/push/pull/publish, share links and hosting live sessions. Cancel anytime.</div>
<div class="card"><b>AI credit</b> · prepaid packs of ${top}<br>Pays for the coding agent when you don't use your own Anthropic key. Charged at cost plus a ${Math.round((AI_MARKUP - 1) * 100)}% service fee.</div>
<p>Payments are processed securely by Stripe. Questions or support: ${contact}.</p>
<p class="muted">Made by ${NAME}.</p>`);
  }

  return { page, home };
};
