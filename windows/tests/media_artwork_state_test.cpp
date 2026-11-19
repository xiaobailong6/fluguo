// Portable tests of the production helper; no Windows SDK, Flutter or WinRT.
#include "../runner/media_artwork_state.h"

#include <chrono>
#include <functional>
#include <future>
#include <iostream>
#include <stdexcept>

namespace {

struct Updater {
  std::string title;
  std::string thumbnail;
  int completions = 0;
};

using Target = std::shared_ptr<Updater>;
using State = MediaArtworkState<Target>;

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

template <typename Action>
void RequireThrows(Action action) {
  bool threw = false;
  try {
    action();
  } catch (const std::runtime_error&) {
    threw = true;
  }
  Require(threw, "simulated WinRT failure must propagate and release the lock");
}

State::Token Begin(State& state, const std::string& path, const Target& target,
                   const std::string& title = "title") {
  return state.Update(path, [&](bool changed) {
    target->title = title;
    if (changed) target->thumbnail.clear();
    return target;
  });
}

bool Finish(State& state, const State::Token& token, const std::string& artwork) {
  return state.Complete(token, [&](const Target& target) {
    target->thumbnail = artwork;
    ++target->completions;
  });
}

void OutOfOrderAndAba() {
  State state;
  auto old_updater = std::make_shared<Updater>();
  auto new_updater = std::make_shared<Updater>();
  const auto a = Begin(state, "A", old_updater);
  const auto b = Begin(state, "B", new_updater);
  Require(Finish(state, b, "B"), "B must complete");
  Require(!Finish(state, a, "A"), "late A must not replace B");
  Require(new_updater->thumbnail == "B" && old_updater->completions == 0,
          "a stale callback must not touch either updater");

  const auto next_a = Begin(state, "A", new_updater);
  Require(a != next_a, "A -> B -> A needs distinct generations");
  Require(!Finish(state, a, "old A"), "path equality is not generation equality");
  Require(Finish(state, next_a, "new A"), "latest A must complete");
  Require(new_updater->thumbnail == "new A", "latest A must remain visible");
}

void ClearThenNewOwner() {
  State state;
  auto old_owner = std::make_shared<Updater>();
  auto new_owner = std::make_shared<Updater>();
  const auto old = Begin(state, "shared-path", old_owner, "old owner");
  state.Clear([&] { old_owner->thumbnail.clear(); });
  Require(!Finish(state, old, "old"), "Clear must invalidate pending artwork");
  const auto fresh = Begin(state, "shared-path", new_owner, "new owner");
  Require(old != fresh, "same path after Clear needs a fresh generation");
  Require(Finish(state, fresh, "new"), "new owner must accept its artwork");
  Require(!Finish(state, old, "old"), "old owner cannot update after replacement");
  Require(new_owner->thumbnail == "new" && new_owner->title == "new owner" &&
              old_owner->completions == 0,
          "new owner metadata and artwork must survive");
}

void EmptyPathAndSamePathRefresh() {
  State state;
  auto first = std::make_shared<Updater>();
  auto current = std::make_shared<Updater>();
  const auto a = Begin(state, "A", first);
  const auto repeated = Begin(state, "A", current, "latest title");
  Require(!repeated, "same path must not start another file operation");
  Require(Finish(state, a, "A"), "in-flight same-path request must still complete");
  Require(first->completions == 0 && current->thumbnail == "A" &&
              current->title == "latest title",
          "completion must resolve the current updater, not a captured old one");

  const auto b = Begin(state, "B", current);
  const auto empty = Begin(state, "", current);
  Require(!empty && current->thumbnail.empty(), "empty path must clear artwork");
  Require(!Finish(state, empty, "empty"), "empty token must never be accepted");
  Require(!Finish(state, b, "B"), "empty path must invalidate pending B");
  Require(!Begin(state, "", current), "repeated empty path must not fetch a file");
  const auto next_b = Begin(state, "B", current);
  Require(b != next_b && !Finish(state, b, "old B"),
          "returning from empty path must not revive B");
  Require(Finish(state, next_b, "new B"), "B after empty path must work");
}

void OwnerDestruction() {
  struct Owner {
    std::shared_ptr<State> state = std::make_shared<State>();
    ~Owner() { state->Close(); }
  };
  std::weak_ptr<State> weak_state;
  std::weak_ptr<Updater> weak_updater;
  std::function<bool()> late;
  {
    Owner owner;
    auto updater = std::make_shared<Updater>();
    weak_state = owner.state;
    weak_updater = updater;
    const auto request = Begin(*owner.state, "A", updater);
    late = [state = owner.state, request] { return Finish(*state, request, "A"); };
    updater.reset();
    Require(!weak_updater.expired(), "state must own the live updater");
  }
  Require(weak_updater.expired(), "Close must release the updater before teardown");
  Require(!weak_state.expired(), "callback must keep its closed state alive");
  Require(!std::async(std::launch::async, late).get(),
          "callback after owner destruction must be harmless");
  {
    auto state = weak_state.lock();
    bool prepared = false;
    const auto after_close = state->Update("B", [&](bool) {
      prepared = true;
      return std::make_shared<Updater>();
    });
    Require(!after_close && !prepared, "Close must be terminal");
    state->Clear([] {});
    Require(!Begin(*state, "C", std::make_shared<Updater>()),
            "Clear must not reopen a destroyed owner");
  }
  late = nullptr;
  Require(weak_state.expired(), "completed callback must not leak shared state");
}

void ExceptionsDoNotReviveRequests() {
  State state;
  auto target = std::make_shared<Updater>();
  const auto a = Begin(state, "A", target);
  RequireThrows([&] {
    state.Update("B", [](bool) -> Target { throw std::runtime_error("prepare"); });
  });
  Require(!Finish(state, a, "A"), "failed preparation must still invalidate A");
  const auto c = Begin(state, "C", target);
  RequireThrows([&] { state.Clear([] { throw std::runtime_error("clear"); }); });
  Require(!Finish(state, c, "C"), "failed Clear must still invalidate C");
  const auto d = Begin(state, "D", target);
  RequireThrows([&] {
    state.Complete(d, [](const Target&) { throw std::runtime_error("apply"); });
  });
  Require(Finish(state, d, "D"), "exception must release the completion lock");
  RequireThrows([&] {
    state.Update("D", [](bool) -> Target { throw std::runtime_error("refresh"); });
  });
  Require(!Finish(state, d, "old D"), "failed refresh cannot leave an old updater");
}

enum class Mutation { kUpdate, kClear, kClose };

void CompletionAndInvalidationAreSerialized(Mutation mutation) {
  State state;
  auto target = std::make_shared<Updater>();
  const auto a = Begin(state, "A", target);
  std::promise<void> applying;
  std::promise<void> release;
  auto released = release.get_future();
  auto completion = std::async(std::launch::async, [&] {
    return state.Complete(a, [&](const Target& updater) {
      // Pause after validation but before the write: this is the TOCTOU window
      // an atomic generation check would leave unprotected.
      applying.set_value();
      released.wait();
      updater->thumbnail = "A";
      ++updater->completions;
    });
  });
  applying.get_future().wait();
  std::promise<void> invalidating;
  State::Token b;
  auto invalidation = std::async(std::launch::async, [&] {
    invalidating.set_value();
    switch (mutation) {
      case Mutation::kUpdate:
        b = Begin(state, "B", target);
        break;
      case Mutation::kClear:
        state.Clear([&] { target->thumbnail.clear(); });
        break;
      case Mutation::kClose:
        state.Close();
        break;
    }
  });
  invalidating.get_future().wait();
  const bool was_blocked = invalidation.wait_for(std::chrono::milliseconds(50)) ==
                           std::future_status::timeout;
  // Always release/join before asserting so a failure cannot strand a worker.
  release.set_value();
  const bool applied = completion.get();
  invalidation.get();
  Require(was_blocked && applied, "invalidation must wait for check AND apply");
  Require(!Finish(state, a, "late A"), "invalidation must reject all later A writes");
  if (mutation == Mutation::kUpdate) {
    Require(target->thumbnail.empty(), "new request must clear old artwork last");
    Require(Finish(state, b, "B") && target->thumbnail == "B", "B must win");
  } else if (mutation == Mutation::kClear) {
    Require(target->thumbnail.empty(), "Clear must run after the in-flight write");
  } else {
    Require(!Begin(state, "B", target), "Close must remain terminal after a race");
  }
}

}  // namespace

int main() {
  try {
    OutOfOrderAndAba();
    ClearThenNewOwner();
    EmptyPathAndSamePathRefresh();
    OwnerDestruction();
    ExceptionsDoNotReviveRequests();
    CompletionAndInvalidationAreSerialized(Mutation::kUpdate);
    CompletionAndInvalidationAreSerialized(Mutation::kClear);
    CompletionAndInvalidationAreSerialized(Mutation::kClose);
    std::cout << "PASS: 8 portable media artwork test groups (not a WinRT test)\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}
