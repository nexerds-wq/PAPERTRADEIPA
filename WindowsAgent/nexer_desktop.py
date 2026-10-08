"""NEXER Repair Windows desktop UI. Hold LEFT mouse and drag ↑ ↓ ← ← → to unlock."""
import base64
import socket
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
import nexer_agent as agent

BG = "#07090e"
PANEL = "#151c25"
FG = "#edf6f5"
ACCENT = "#3ce1ca"
CODE = ("up", "down", "left", "left", "right")

class Desktop:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("NEXER Repair")
        self.root.geometry("1030x700")
        self.root.minsize(780, 510)
        self.root.configure(bg=BG)
        self.progress = 0
        self.start = None
        self.image = ""
        self.server_started = False
        self.screen = tk.Frame(self.root, bg="#000000")
        self.screen.pack(fill="both", expand=True)
        self.screen.bind("<ButtonPress-1>", self.press)
        self.screen.bind("<ButtonRelease-1>", self.release)
        self.screen.focus_set()

    def press(self, event):
        self.start = (event.x, event.y)

    def release(self, event):
        if self.start is None:
            return
        dx, dy = event.x - self.start[0], event.y - self.start[1]
        self.start = None
        if max(abs(dx), abs(dy)) < 65:
            return
        direction = ("right" if dx > 0 else "left") if abs(dx) > abs(dy) else ("down" if dy > 0 else "up")
        if direction == CODE[self.progress]:
            self.progress += 1
            if self.progress == len(CODE):
                self.progress = 0
                self.unlock()
        else:
            self.progress = 1 if direction == CODE[0] else 0

    def unlock(self):
        self.screen.destroy()
        header = tk.Frame(self.root, bg=BG)
        header.pack(fill="x", padx=25, pady=(16, 8))
        tk.Label(header, text="NEXER", font=("Segoe UI", 30, "bold"),
                 bg=BG, fg=ACCENT).pack(side="left")
        tk.Label(header, text="WINDOWS REPAIR  •  OLLAMA AI",
                 font=("Segoe UI", 11), bg=BG, fg="#a3b3ba").pack(side="left", padx=25)
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("TNotebook", background=BG, borderwidth=0)
        style.configure("TNotebook.Tab", padding=(16, 10), font=("Segoe UI", 11), background=PANEL, foreground=FG)
        style.map("TNotebook.Tab", background=[("selected", "#1b746b")])
        self.tabs = ttk.Notebook(self.root)
        self.tabs.pack(fill="both", expand=True, padx=25, pady=14)
        self.build_dashboard()
        self.build_chat()
        self.build_tools()
        self.build_history()
        self.build_settings()

    def tab(self, title):
        area = tk.Frame(self.tabs, bg=BG)
        self.tabs.add(area, text=title)
        return area

    def button(self, parent, text, fn):
        return tk.Button(parent, text=text, command=fn, bg="#195f58", fg="white",
                         activebackground="#23877b", activeforeground="white",
                         relief="flat", padx=14, pady=9, font=("Segoe UI", 10, "bold"),
                         cursor="hand2")

    def output_box(self, parent, height=18):
        box = tk.Text(parent, height=height, bg=PANEL, fg=FG, insertbackground=FG,
                      font=("Consolas", 10), relief="flat", padx=12, pady=10, wrap="word")
        box.pack(fill="both", expand=True, pady=(14, 0))
        return box

    def log(self, box, text):
        box.insert("end", text + "\n")
        box.see("end")

    def worker(self, job, callback):
        def task():
            try:
                output = job()
                self.root.after(0, lambda: callback(output))
            except Exception as exc:
                error = str(exc)
                self.root.after(0, lambda: messagebox.showerror("NEXER", error))
        threading.Thread(target=task, daemon=True).start()

    def build_dashboard(self):
        page = self.tab("Dashboard")
        tk.Label(page, text="Diagnose your entire PC", bg=BG, fg=FG,
                 font=("Segoe UI", 19, "bold")).pack(anchor="w", pady=(12, 4))
        tk.Label(page, text="Windows • Drivers • GPU • RAM • Audio • Network • Bluetooth • Security • Crashes",
                 bg=BG, fg="#9aadb5", font=("Segoe UI", 11)).pack(anchor="w")
        self.button(page, "DIAGNOSE MY PC", self.full_scan).pack(anchor="w", pady=(18, 2))
        self.scan_out = self.output_box(page)

    def full_scan(self):
        self.log(self.scan_out, "Starting PC scan...")
        def done(data):
            for entry in data.get("results", []):
                self.log(self.scan_out, "\n=== " + entry["label"] + " ===\n" + entry["output"][:1800])
            self.log(self.scan_out, "\nFinished collecting diagnostics. Review warnings before repairing.")
        self.worker(agent.diagnose, done)

    def build_chat(self):
        page = self.tab("Ollama AI")
        tk.Label(page, text="Ask NEXER anything about your PC",
                 bg=BG, fg=FG, font=("Segoe UI", 18, "bold")).pack(anchor="w", pady=(12, 4))
        self.chat_out = self.output_box(page, 19)
        bottom = tk.Frame(page, bg=BG)
        bottom.pack(fill="x", pady=12)
        self.chat_entry = tk.Entry(bottom, bg=PANEL, fg=FG, insertbackground=FG,
                                  relief="flat", font=("Segoe UI", 12))
        self.chat_entry.pack(side="left", fill="x", expand=True, ipady=10, padx=(0, 8))
        self.chat_entry.bind("<Return>", lambda _: self.send_chat())
        self.button(bottom, "IMAGE", self.choose_image).pack(side="left", padx=4)
        self.button(bottom, "SEND", self.send_chat).pack(side="left")
        self.chat_model = "qwen3:4b"
        self.vision_model = "qwen3-vl:4b"

    def choose_image(self):
        path = filedialog.askopenfilename(filetypes=[
            ("Images", "*.png *.jpg *.jpeg *.webp"), ("All files", "*.*")
        ])
        if not path:
            return
        with open(path, "rb") as f:
            data = f.read(5_000_001)
        if len(data) > 5_000_000:
            messagebox.showwarning("Image too large", "Choose an image under 5 MB.")
            return
        self.image = base64.b64encode(data).decode()
        self.log(self.chat_out, "[Image attached: " + path.split("/")[-1].split("\\")[-1] + "]")

    def send_chat(self):
        text = self.chat_entry.get().strip()
        if not text and not self.image:
            return
        self.chat_entry.delete(0, "end")
        photo, self.image = self.image, ""
        self.log(self.chat_out, "\nYOU: " + (text or "Analyze attached image") + "\nNEXER: analyzing...")
        model = self.vision_model if photo else self.chat_model
        def done(resp):
            self.log(self.chat_out, "\nNEXER: " + resp.get("reply", "No answer"))
            for action in resp.get("pending", []):
                self.ask_approval(action)
        self.worker(lambda: agent.chat(text, photo, model), done)

    def ask_approval(self, action):
        if not messagebox.askyesno("Repair approval", "Allow NEXER to run:\n" +
                                   action["label"] + "\nRisk: " + action["risk"] +
                                   "\n\nThis can change Windows settings."):
            self.log(self.chat_out, "Repair not approved: " + action["label"])
            return
        self.worker(lambda: agent.approve_tool(action["id"]),
                    lambda response: self.log(self.chat_out,
                        "\nREPAIR RESULT:\n" + response.get("output", "No output")))

    def build_tools(self):
        page = self.tab("Repair Tools")
        tk.Label(page, text="Approved tools only. No unrestricted command execution.",
                 bg=BG, fg=FG, font=("Segoe UI", 13)).pack(anchor="w", pady=12)
        frame = tk.Frame(page, bg=BG)
        frame.pack(fill="x")
        self.selected_tool = tk.StringVar()
        labels = {v[0] + " [" + v[1] + "]": k for k, v in agent.TOOLS.items()}
        self.label_to_tool = labels
        self.tool_combo = ttk.Combobox(frame, state="readonly", textvariable=self.selected_tool,
                                       values=list(labels.keys()), width=55)
        self.tool_combo.pack(side="left", padx=(0, 15))
        self.tool_combo.current(0)
        self.button(frame, "RUN / REQUEST", self.run_tool).pack(side="left")
        self.tool_out = self.output_box(page)

    def run_tool(self):
        tool = self.label_to_tool.get(self.selected_tool.get())
        if not tool:
            return
        def done(result):
            if result.get("pending"):
                self.ask_approval(result["pending"])
            else:
                self.log(self.tool_out, "\n" + agent.TOOLS[tool][0] + "\n" + result.get("output", ""))
        self.worker(lambda: agent.request_tool(tool), done)

    def build_history(self):
        page = self.tab("Repair History")
        self.button(page, "REFRESH HISTORY", self.load_history).pack(anchor="w", pady=(12, 0))
        self.history_out = self.output_box(page)
        self.load_history()

    def load_history(self):
        self.history_out.delete("1.0", "end")
        for item in agent.read_history():
            self.log(self.history_out, item["time"] + " | " + item["action"] +
                     " | " + item["status"] + "\n" + item["detail"] + "\n")

    def build_settings(self):
        page = self.tab("Settings / Phone Pairing")
        tk.Label(page, text="iPhone pairing (trusted private network only)",
                 bg=BG, fg=FG, font=("Segoe UI", 16, "bold")).pack(anchor="w", pady=14)
        tk.Label(page, text="The Windows agent must be running for the IPA to diagnose this PC.",
                 bg=BG, fg=FG).pack(anchor="w")
        self.button(page, "START PHONE AGENT", self.start_phone_agent).pack(anchor="w", pady=15)
        self.phone_info = tk.Label(page, text="Phone agent not started",
                                   bg=BG, fg="#b1c5ce", justify="left")
        self.phone_info.pack(anchor="w")
        self.button(page, "COPY PAIRING KEY", self.copy_key).pack(anchor="w", pady=10)
        tk.Label(page, text="Ollama chat model", bg=BG, fg=FG).pack(anchor="w", pady=(18, 4))
        self.chat_model_entry = tk.Entry(page, bg=PANEL, fg=FG, insertbackground=FG)
        self.chat_model_entry.insert(0, self.chat_model)
        self.chat_model_entry.pack(fill="x")
        tk.Label(page, text="Vision model", bg=BG, fg=FG).pack(anchor="w", pady=(12, 4))
        self.vision_model_entry = tk.Entry(page, bg=PANEL, fg=FG, insertbackground=FG)
        self.vision_model_entry.insert(0, self.vision_model)
        self.vision_model_entry.pack(fill="x")
        self.button(page, "SAVE MODELS", self.save_models).pack(anchor="w", pady=12)
        tk.Label(page, text="Do NOT port-forward port 8765. This first build uses HTTP on LAN, not TLS.",
                 bg=BG, fg="#ffb86b").pack(anchor="w", pady=14)

    def save_models(self):
        self.chat_model = self.chat_model_entry.get().strip() or "qwen3:4b"
        self.vision_model = self.vision_model_entry.get().strip() or "qwen3-vl:4b"
        messagebox.showinfo("NEXER", "Models saved for this session.")

    def copy_key(self):
        self.root.clipboard_clear()
        self.root.clipboard_append(agent.KEY)
        messagebox.showinfo("Copied", "Pairing key copied. Keep it private.")

    def start_phone_agent(self):
        if self.server_started:
            return
        if not messagebox.askyesno(
            "Local network access",
            "Allow paired phones on your trusted Wi-Fi to access NEXER repair functions?\n"
            "Only approved repair tools are allowed. Do not use public Wi-Fi."):
            return
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("192.0.2.1", 9))
                address = s.getsockname()[0]
        except OSError:
            address = "YOUR_PC_IP"
        self.server_started = True
        threading.Thread(target=agent.start_server,
                         args=("0.0.0.0", 8765), daemon=True).start()
        self.phone_info.config(text=f"In the IPA, enter:\nhttp://{address}:8765\n"
                                    "Then paste the pairing key.\n"
                                    "Windows Firewall may ask for private-network access.")

    def run(self):
        self.root.mainloop()

if __name__ == "__main__":
    Desktop().run()
