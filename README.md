This is the **platform** asset for TMC's **Dot** collection. Identity, profile and avatar are three assets that deliberately do not know about each other, and this is the one that joins them into a single way in.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Identity, Profile and Avatar, Joined Up
The piece that turns the dot-\* family into something a person can sign into.

dot-auth says who you are. dot-user says what we know about you. dot-user-avatar
says what you look like. None of them knows about the others — that is what makes
them adoptable one at a time — and so nothing joined them up. This does.

Part of the [dot-\*](../) family. Requires [dot-core](../dot-core) and
[dot-server](../dot-server); finds dot-auth, dot-user and dot-user-avatar at runtime
and works with any subset of them, including none.

## Install

Copy `addons/dot_platform/` and `addons/dot_core/` into your project, plus whichever
of dot-auth, dot-user and dot-user-avatar you want. Enable them in
*Project → Project Settings → Plugins*.

## Use

```gdscript
var hub := DotPlatformHub.new()
add_child(hub)

var admitted := await hub.admit(identity)      # identity from dot-auth
var player: DotPlatformPlayer = admitted.value

player.key()            # scoped id — what everything else uses
player.display_name()   # from the profile, falling back to the identity
player.avatar           # resolved, conformed, entitlement-checked
```

On a dot-server, load the module instead and it does all of that per connection:

```gdscript
server.modules.load_module("res://addons/dot_platform/dot_platform_module.gd")
```

It finds the hub through `DotRegistry`, admits every authenticated client, puts the
result on `session.data["platform"]`, applies the profile's name, and releases the
state when they leave. It adds `platform_status` and `platform_name` to the console.

## The translation it exists to do

```
identity.uid          "backbone:acc-1"     global; a server must never see this
   -> profile.user_key  "sWrM4ym4beWFH0Nx"  scoped; what everything else keys on
   -> avatar filed under the SAME scoped key
```

Keying the avatar on the account id instead works perfectly in testing and quietly
hands every server operator a global identifier for every player. `DotPlatformHub` is
the only place that translation happens, and `DotPlatformPlayer.account_uid()` is
named to be conspicuous at the call site.

## Everything optional stays optional

| Installed | What happens |
| --- | --- |
| all three | profile, avatar, entitlements, onboarding flag |
| dot-user only | a profile and a scoped key; nobody has an avatar and nothing asks |
| neither | a player with a name from the identity and no scoped key |
| a broken store | the player still gets in, visible, with nothing persisted over |

A sandbox that required all three to start would be unusable on the first day of a
project, which is the day people decide whether to adopt something.

## Examples

Both exit non-zero on failure.

```bash
# All four addons in one process: real RSA keys, a real ticket, real stores.
godot --headless --path . res://examples/seam_selftest.tscn      # 62 checks

# A real server and a real client over a real socket, in one process.
godot --headless --path . res://examples/sandbox_server.tscn     # 22 checks
```

`sandbox_server` boots a `DotServer`, loads the module, connects a `DotClientLink`
over loopback and lets the whole signon run — transport, challenge, credentials,
authentication, content, load, spawn — with the platform resolving a profile and an
avatar along the way. Nothing is called by hand.

It found two bugs in dot-server on its first run, both of which made a client unable
to join at all. See `CLAUDE.md`.

MIT licensed.
