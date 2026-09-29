//
//  CodableAppStorage.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 7/11/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import Combine
import OSLog

/// A property wrapper type that reflects a `Codable` value from `UserDefaults` and invalidates a view on a change when said value changes.
@MainActor
@frozen @propertyWrapper public struct CodableAppStorage<Value>: @MainActor DynamicProperty where Value: Codable & Equatable {
    @StateObject private var observer: CodableUserDefaultsObserver<Value>
    @State private var transaction: Transaction = .init()
    
    private let key: String
    private let store: UserDefaults
    
    public var wrappedValue: Value {
        get { observer.value }
        nonmutating set {
            withTransaction(transaction) {
                _ = try? store.encodeAndSet(newValue, forKey: key)
            }
        }
    }
    
    public var projectedValue: Binding<Value> {
        .init(
            get: { self.observer.value },
            set: { newValue in
                withTransaction(self.transaction) {
                    _ = try? store.encodeAndSet(newValue, forKey: key)
                }
            }
        )
    }
    
    public mutating func update() {
        _observer.update()
        _transaction.update()
    }
}

extension CodableAppStorage {
    /**
     Creates a property that can read and write to a codable user default.
     
     - Parameters:
     - wrappedValue: The default value if a codable value is not specified for the given key.
     - key: The key to read and write the value to in the user defaults store.
     - store: The user defaults store to read and write to. A value of `nil` will use the `.standard` store.
     */
    public init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) {
        self.key = key
        self.store = store
        
        let initialValue: Value
        if let actualValue = try? self.store.decodeAndGet(Value.self, forKey: key) {
            initialValue = actualValue
        } else {
            do {
                try self.store.encodeAndSet(wrappedValue, forKey: key)
            } catch {
                Logger.app.error("""
                    CodableAppStorage was unable to re-encode wrappedValue as a fallback.
                    This may cause unintended behaviour.
                    """)
            }
            initialValue = wrappedValue
        }
        
        let capturedStore: UserDefaults = self.store
        self._observer = .init(
            wrappedValue: .init(key: key,
                                defaultValue: wrappedValue,
                                store: capturedStore,
                                initialValue: initialValue)
        )
        
        self._transaction = .init(initialValue: .init())
    }
}

extension CodableAppStorage where Value: ExpressibleByNilLiteral {
    /**
     Creates a property that can read and write an Optional codable user
     default.
     
     Defaults to nil if there is no restored value.
     
     - Parameters:
     - key: The key to read and write the value to in the user defaults store.
     - store: The user defaults store to read and write to. A value of `nil` will use the user default store from the environment.
     */
    public init(_ key: String, store: UserDefaults = .standard) {
        self.key = key
        self.store = store
        
        let initialValue: Value = (try? self.store.decodeAndGet(Value.self, forKey: key)) ?? nil
        
        let capturedStore: UserDefaults = self.store
        self._observer = .init(
            wrappedValue: .init(key: key,
                                defaultValue: nil,
                                store: capturedStore,
                                initialValue: initialValue)
        )
        self._transaction = .init(initialValue: .init())
    }
}

/// Internal observable object that monitors UserDefaults changes for Codable types.
@MainActor
@usableFromInline final class CodableUserDefaultsObserver<T>: ObservableObject where T: Codable & Equatable {
    @Published public private(set) var value: T
    
    private let key: String
    private let defaultValue: T
    private let store: UserDefaults
    private var cancellable: AnyCancellable?
    
    private let log: Logger = .custom(category: "CodableUserDefaultsObserver")
    
    // No `deinit`. There was one — `withExtendedLifetime(cancellable) { $0?.cancel() }` — and
    // it did nothing this class doesn't already do: `AnyCancellable` cancels its subscription
    // when it is released, and releasing this observer releases the one it holds.
    //
    // It also crashed the compiler. `swift-frontend` 6.3.3 recursed until it ran out of stack
    // in `isCallerAndCalleeLayoutConstraintsCompatible` during `EarlyPerfInliner`, inlining
    // that `withExtendedLifetime` closure into the `deinit` of a generic `@usableFromInline`
    // class. Only in Release, because `-Onone` never runs that pass, so a Debug build and the
    // whole test suite were perfectly green while `xcodebuild archive` could not finish at all.
    //
    // Deleted rather than worked around with `@inline(never)`: the code was redundant, and a
    // redundant line that crashes the optimiser is not a line worth keeping.
    
    convenience init(key: String, defaultValue: T, store: UserDefaults = .standard) {
        self.init(key: key,
                  defaultValue: defaultValue,
                  store: store,
                  initialValue: (try? store.decodeAndGet(T.self, forKey: key)) ?? defaultValue)
    }
    
    /**
     Creates an observer that monitors a `UserDefaults` key for changes.
     
     - Parameters:
        - key: The `UserDefaults` key to monitor.
        - defaultValue: The fallback value if decoding fails or the key doesn't exist.
        - store: The `UserDefaults` store to monitor.
        - initialValue: The initial value to use, typically loaded from `UserDefaults` before initialization.
     */
    public init(key: String, defaultValue: T, store: UserDefaults = .standard, initialValue: T) {
        self.key = key
        self.defaultValue = defaultValue
        self.store = store
        self.value = initialValue
        
        self.cancellable = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification, object: store)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFromDefaults()
            }
    }
    
    private func updateFromDefaults() {
        let newValue: T = (try? store.decodeAndGet(T.self, forKey: key)) ?? defaultValue
        guard newValue != value else { return }
        value = newValue
    }
}
