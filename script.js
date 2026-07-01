const copyButton = document.querySelector("[data-copy-button]");
const copyLabel = document.querySelector("[data-copy-label]");
const copyStatus = document.querySelector("#copy-status");
const installCommand = document.querySelector("#install-command");

let resetTimer;

async function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    await navigator.clipboard.writeText(text);
    return;
  }

  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  textarea.style.pointerEvents = "none";
  document.body.appendChild(textarea);
  textarea.select();

  const copied = document.execCommand("copy");
  textarea.remove();

  if (!copied) {
    throw new Error("Copy command was not accepted by the browser.");
  }
}

function showCopyState(label, status, isCopied = false) {
  copyLabel.textContent = label;
  copyStatus.textContent = status;
  copyButton.classList.toggle("is-copied", isCopied);
}

copyButton?.addEventListener("click", async () => {
  const command = installCommand?.textContent.trim();
  if (!command) return;

  window.clearTimeout(resetTimer);

  try {
    await copyText(command);
    showCopyState("Copied!", "Install command copied to clipboard.", true);
  } catch {
    showCopyState("Try again", "Unable to copy the install command.");
  }

  resetTimer = window.setTimeout(() => {
    showCopyState("Copy", "");
  }, 2200);
});
