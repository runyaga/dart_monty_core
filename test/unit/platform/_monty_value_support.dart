// Shared helpers for the MontyValue family tests (not a test file).

/// Two separately built values from one constructor expression.
///
/// The equality and hash tests need two distinct, equal objects: a `const`
/// twin would be one object and the comparison would never run. Building both
/// here keeps each test from repeating the same construction twice.
(T, T) twins<T>(T Function() make) => (make(), make());

/// Casts a nullable projection (`toJson()` and the like) to [T].
///
/// A null still fails the cast, exactly as `value! as T` would, without the
/// non-null assertion.
T castTo<T>(Object? value) => value as T;
