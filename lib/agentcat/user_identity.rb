# typed: true

module AgentCat
  # Return value of `Options#identify`. `user_id` is required; the rest is optional
  # metadata reported alongside every event tied to this actor.
  class UserIdentity < T::Struct
    const :user_id, String
    const :user_name, T.nilable(String), default: nil
    const :user_data, T.nilable(T::Hash[T.untyped, T.untyped]), default: nil
  end
end
