Don't over-engineer. Don't create unnecessary problems to slow us down
- Don't use Paramiko. Use ssh command
- Speed up VM provisioning. Combine commands in shell scripts, instead of a separate command for each step.

Fix names. No abbreviations. Use one word instead of may wherever possible
- VM Image - Virtual Machine Image
- Rethink Metal Node, SSH Command, Metal Command

Corrections
 - Use the latest FIRECRACKER_VERSION v1.15.1
 - Use static names for VMs. UUID etc. Don't change the names after the archive.
 - Don't mix Python and non-Python code, e.g. shell scripts, templates, etc. Keep them in separate files for readability and formatting.
 - Don't mix shell commands and templates.
 - DigitalOcean provides a /64 IPv6 subnet, but only /124 is routable.

Picking a route now might change later
- Unsure about a good SSH model. One command ("ls" then "mkdir"). One "task" (e.g. commands in a shell script). Go with one task at a time. Evolve later. e.g zx (check references)
- Unsure about bootstrapping. Do it with script based for now. Evolve later. e.g. pyinfra (check references)

As a rule, don't import anything. If we find good ideas like pyinfra, zx, then build a minimal implementation ourselves.

Update the specification to fix these issues. Add reasoning to the spec, if the reasons are not obvious.