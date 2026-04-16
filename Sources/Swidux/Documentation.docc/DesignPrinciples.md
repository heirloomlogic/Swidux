# Design Principles

The philosophy behind Swidux's approach to state management and persistence.

## Overview

Swidux is built around a small set of principles that keep persistence invisible and state management predictable.

## Persistence Is Invisible

Reducers mutate ``EntityStore`` properties; the middleware handles database writes and load/loaded action pairs. You never write `db.save()` in a feature.

## Synchronous State, Async Persistence

State updates synchronously in the reducer for instant UI feedback. Persistence happens asynchronously — rapid mutations coalesce behind a debounce timer so rapid taps produce a single database write.

## Reducers Are Pure

Reducers are pure state transformations. They accept `inout State` and return an optional ``Effect`` for async work. Side effects live in effects, not reducers.

## Bind to the Store, Not to @State

Form inputs bind to the store via `Binding(get:set:)` rather than `@State` buffering. This keeps the store as the single source of truth and ensures every mutation flows through the reducer.
