import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { FoxSay } from "./FoxSay";
import "./styles.css";

const params = new URLSearchParams(window.location.search);
const Root = params.get("mode") === "say" ? FoxSay : App;

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Root />
  </StrictMode>
);
