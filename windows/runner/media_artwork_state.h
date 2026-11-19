#ifndef RUNNER_MEDIA_ARTWORK_STATE_H_
#define RUNNER_MEDIA_ARTWORK_STATE_H_

#include <memory>
#include <mutex>
#include <optional>
#include <string>

// Independent of WinRT so the callback/owner lifetime rules can be tested offline.
// All callbacks below run synchronously under mutex_ and must not re-enter this
// state. Register async completions only after Update returns (they can run inline).
template <typename Target>
class MediaArtworkState {
  struct Generation {};

 public:
  // Identity, rather than a wrapping counter or path, distinguishes A -> B -> A
  // and a new owner after Clear, even when both owners request the same path.
  using Token = std::shared_ptr<const Generation>;

  template <typename Prepare>
  Token Update(const std::string& path, Prepare prepare) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_) return {};
    const bool changed = path != path_;
    if (changed) {
      token_ = path.empty() ? Token{} : std::make_shared<Generation>();
      path_ = path;
    }
    // Invalidate before touching metadata, even if a WinRT call throws. Clearing
    // the target prevents a completion from retaining an obsolete updater.
    target_.reset();
    target_ = prepare(changed);
    return changed ? token_ : Token{};
  }

  template <typename Apply>
  bool Complete(const Token& token, Apply apply) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_ || !token || token != token_ || !target_) return false;
    // Check AND write share the invalidation lock: an atomic check alone would
    // allow Clear/Update/Close between validation and Thumbnail/Update.
    apply(*target_);
    return true;
  }

  template <typename ClearDisplay>
  void Clear(ClearDisplay clear_display) {
    std::lock_guard<std::mutex> lock(mutex_);
    InvalidateLocked();
    clear_display();
  }

  void Close() {
    std::lock_guard<std::mutex> lock(mutex_);
    // Terminal invalidation also releases the WinRT target while its owner is
    // still alive. Late callbacks may retain only this closed shared state.
    closed_ = true;
    InvalidateLocked();
  }

 private:
  void InvalidateLocked() {
    token_.reset();
    target_.reset();
    path_.clear();
  }

  std::mutex mutex_;
  bool closed_ = false;
  std::string path_;
  Token token_;
  std::optional<Target> target_;
};

#endif  // RUNNER_MEDIA_ARTWORK_STATE_H_
