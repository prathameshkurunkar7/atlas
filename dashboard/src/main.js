import { createApp } from "vue";
import "./style.css";
// Importing the theme module applies the persisted mode (system/light/dark) to
// <html> before the app mounts, so there's no flash of the wrong theme.
import "./theme.js";
import App from "./App.vue";

createApp(App).mount("#app");
