import { browser } from "$app/environment";
import { config } from "$lib/stores/settings.svelte";

export class AudioService {
  private static isSpeaking = false;

  /**
   * Send a browser notification if the page is hidden
   */
  static notify(text: string) {
    if (!browser) return;
    if (
      document.visibilityState === "hidden" &&
      "Notification" in window &&
      Notification.permission === "granted"
    ) {
      new Notification("Jenova JCA", {
        body: text.slice(0, 150) + (text.length > 150 ? "..." : ""),
        icon: "/favicon.jpg",
      });
    }
  }

  /**
   * Speak text using Web Speech API with JCA custom tuning
   */
  static speak(text: string) {
    if (!browser || !window.speechSynthesis) return;

    const currentConfig = config();
    if (!currentConfig.useAudioVoice) return;

    // Clean text: remove thinking blocks and HTML tags
    const cleanText = text
      .replace(/<think>[\s\S]*?(?:<\/think>|$)/g, "")
      .replace(/<[^>]*>?/gm, "")
      .trim();

    if (!cleanText) return;

    const synth = window.speechSynthesis;
    synth.cancel(); // Stop any current speech

    const utterance = new SpeechSynthesisUtterance(cleanText);
    const voices = synth.getVoices();

    // Find preferred voice
    let preferredVoice = currentConfig.selectedVoiceURI
      ? voices.find((v) => v.voiceURI === currentConfig.selectedVoiceURI)
      : undefined;

    if (!preferredVoice) {
      // Sophisticated/Natural female voice fallback
      preferredVoice =
        voices.find(
          (v) => v.name.includes("Aria") && v.name.includes("Natural"),
        ) ||
        voices.find(
          (v) => v.name.includes("Jenny") && v.name.includes("Natural"),
        ) ||
        voices.find(
          (v) => v.name.includes("Sonia") && v.name.includes("Natural"),
        ) ||
        voices.find(
          (v) => v.name.includes("Natasha") && v.name.includes("Natural"),
        ) ||
        voices.find(
          (v) =>
            v.name.includes("Google") &&
            v.name.includes("Female") &&
            !v.localService,
        ) ||
        voices.find((v) => v.name.includes("Samantha")) ||
        voices.find(
          (v) =>
            v.name.toLowerCase().includes("female") && v.lang.startsWith("en"),
        );
    }

    if (preferredVoice) utterance.voice = preferredVoice;

    // JCA "Husky/Poised" Tuning
    // 0.85 pitch for husky edge, 0.95 rate for elegant/slower delivery
    utterance.pitch = 0.85;
    utterance.rate = 0.95;
    utterance.volume = 1.0;

    utterance.onstart = () => {
      this.isSpeaking = true;
    };
    utterance.onend = () => {
      this.isSpeaking = false;
    };
    utterance.onerror = () => {
      this.isSpeaking = false;
    };

    synth.speak(utterance);
  }

  static stop() {
    if (browser && window.speechSynthesis) {
      window.speechSynthesis.cancel();
      this.isSpeaking = false;
    }
  }

  static getSpeakingState() {
    return this.isSpeaking;
  }
}
