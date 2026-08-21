# Run a Website From the SwiftUI Client

The SwiftUI client can start a website on the connected environment. It opens
the website on the current device.

## Requirements

Use one of these project types:

- A project script with a preview URL.
- A Next.js, Vite, Astro, or Create React App package with a run script.

For a package, T3 Code uses the first available script from this list:

1. `dev`
2. `start`
3. `preview`

## Start the Website

1. Open a thread for the website project.
2. Open the thread menu.
3. Select **Run** or **Run Website**.

T3 Code starts the script in a thread terminal. It waits for the website to
accept connections. Then it opens the website in the system browser.

The progress panel can close while the website starts. The start process
continues, and its status remains next to the thread menu.

## Remote Connections

The development server listens on all network interfaces. T3 Code replaces a
localhost preview host with the host of the connected environment.

The device must have network access to the preview port. Direct local-network
and tailnet connections support this access.
