# AI assistant usage log

Assistant: GitHub Copilot agent in VS Code (chat + terminal/file tools). Entries are things that actually
happened while building this repository, in order. This is the raw material for the one-page note in
[part4-ai-note.md](part4-ai-note.md). It records the assistant's mistakes as well as the useful output.

 What happened | How it was caught | Outcome |
|---|---|---|---|---|

`kubeadm join` to the VIP timed out. The assistant's first answer was a ranked list of likely causes (kube-vip interface, `super-admin.conf`, expired token). **It was off target**: the real cause was that Lima's `vzNAT` network isolates VMs from each other. | The assistant was asked to run diagnostics instead of guessing: `ip neigh` showed `FAILED`/`INCOMPLETE`, a 5x5 ping matrix failed 20/20 while the host reached every VM. | Network changed to `lima: shared` (socket_vmnet). Lesson: ask the assistant for measurements, not hypotheses. |

