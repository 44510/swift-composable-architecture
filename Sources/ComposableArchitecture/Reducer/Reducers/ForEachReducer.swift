import OrderedCollections

extension Reducer {
  /// Embeds a child reducer in a parent domain that works on elements of a collection in parent
  /// state.
  ///
  /// For example, if a parent feature holds onto an array of child states, then it can perform
  /// its core logic _and_ the child's logic by using the `forEach` operator:
  ///
  /// ```swift
  /// struct Parent: Reducer {
  ///   struct State {
  ///     var rows: IdentifiedArrayOf<Row.State>
  ///     // ...
  ///   }
  ///   enum Action {
  ///     case row(id: Row.State.ID, action: Row.Action)
  ///     // ...
  ///   }
  ///
  ///   var body: some Reducer<State, Action> {
  ///     Reduce { state, action in
  ///       // Core logic for parent feature
  ///     }
  ///     .forEach(\.rows, action: /Action.row) {
  ///       Row()
  ///     }
  ///   }
  /// }
  /// ```
  ///
  /// > Tip: We are using `IdentifiedArray` from our
  /// [Identified Collections][swift-identified-collections] library because it provides a safe
  /// and ergonomic API for accessing elements from a stable ID rather than positional indices.
  ///
  /// The `forEach` forces a specific order of operations for the child and parent features. It
  /// runs the child first, and then the parent. If the order was reversed, then it would be
  /// possible for the parent feature to remove the child state from the array, in which case the
  /// child feature would not be able to react to that action. That can cause subtle bugs.
  ///
  /// It is still possible for a parent feature higher up in the application to remove the child
  /// state from the array before the child has a chance to react to the action. In such cases a
  /// runtime warning is shown in Xcode to let you know that there's a potential problem.
  ///
  /// [swift-identified-collections]: http://github.com/pointfreeco/swift-identified-collections
  ///
  /// - Parameters:
  ///   - toElementsState: A writable key path from parent state to an `IdentifiedArray` of child
  ///     state.
  ///   - toElementAction: A case path from parent action to child identifier and child actions.
  ///   - element: A reducer that will be invoked with child actions against elements of child
  ///     state.
  /// - Returns: A reducer that combines the child reducer with the parent reducer.
  @inlinable
  @warn_unqualified_access
  public func forEach<ElementState, ElementAction, ID: Hashable, Element: Reducer>(
    _ toElementsState: WritableKeyPath<State, IdentifiedArray<ID, ElementState>>,
    action toElementAction: CasePath<Action, (ID, ElementAction)>,
    @ReducerBuilder<ElementState, ElementAction> element: () -> Element,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) -> _ForEachReducer<Self, ID, Element>
  where ElementState == Element.State, ElementAction == Element.Action {
    _ForEachReducer(
      parent: self,
      toElementsState: toElementsState,
      toElementAction: toElementAction,
      element: element(),
      fileID: fileID,
      line: line
    )
  }
}

public struct _ForEachReducer<
  Parent: Reducer, ID: Hashable, Element: Reducer
>: Reducer {
  @usableFromInline
  let parent: Parent

  @usableFromInline
  let toElementsState: WritableKeyPath<Parent.State, IdentifiedArray<ID, Element.State>>

  @usableFromInline
  let toElementAction: CasePath<Parent.Action, (ID, Element.Action)>

  @usableFromInline
  let element: Element

  @usableFromInline
  let fileID: StaticString

  @usableFromInline
  let line: UInt

  @Dependency(\.navigationIDPath) var navigationIDPath

  @usableFromInline
  init(
    parent: Parent,
    toElementsState: WritableKeyPath<Parent.State, IdentifiedArray<ID, Element.State>>,
    toElementAction: CasePath<Parent.Action, (ID, Element.Action)>,
    element: Element,
    fileID: StaticString,
    line: UInt
  ) {
    self.parent = parent
    self.toElementsState = toElementsState
    self.toElementAction = toElementAction
    self.element = element
    self.fileID = fileID
    self.line = line
  }

  public func reduce(
    into state: inout Parent.State, action: Parent.Action
  ) -> Effect<Parent.Action> {
    let elementEffects = self.reduceForEach(into: &state, action: action)

    let idsBefore = state[keyPath: self.toElementsState].ids
    let parentEffects = self.parent.reduce(into: &state, action: action)
    let idsAfter = state[keyPath: self.toElementsState].ids

    let elementCancelEffects: Effect<Parent.Action> =
      areOrderedSetsDuplicates(idsBefore, idsAfter)
      ? .none
      : .merge(
        idsBefore.subtracting(idsAfter).map {
          ._cancel(
            id: NavigationID(id: $0, keyPath: self.toElementsState),
            navigationID: self.navigationIDPath
          )
        }
      )

    return .merge(
      elementEffects,
      parentEffects,
      elementCancelEffects
    )
  }

  func reduceForEach(
    into state: inout Parent.State, action: Parent.Action
  ) -> Effect<Parent.Action> {
    guard let (id, elementAction) = self.toElementAction.extract(from: action) else { return .none }
    if state[keyPath: self.toElementsState][id: id] == nil {
      runtimeWarn(
        """
        A "forEach" at "\(self.fileID):\(self.line)" received an action for a missing element. …

          Action:
            \(debugCaseOutput(action))

        This is generally considered an application logic error, and can happen for a few reasons:

        • A parent reducer removed an element with this ID before this reducer ran. This reducer \
        must run before any other reducer removes an element, which ensures that element reducers \
        can handle their actions while their state is still available.

        • An in-flight effect emitted this action when state contained no element at this ID. \
        While it may be perfectly reasonable to ignore this action, consider canceling the \
        associated effect before an element is removed, especially if it is a long-living effect.

        • This action was sent to the store while its state contained no element at this ID. To \
        fix this make sure that actions for this reducer can only be sent from a view store when \
        its state contains an element at this id. In SwiftUI applications, use "ForEachStore".
        """
      )
      return .none
    }
    let navigationID = NavigationID(id: id, keyPath: self.toElementsState)
    let elementNavigationID = self.navigationIDPath.appending(navigationID)
    return self.element
      .dependency(\.navigationIDPath, elementNavigationID)
      .reduce(into: &state[keyPath: self.toElementsState][id: id]!, action: elementAction)
      .map { self.toElementAction.embed((id, $0)) }
      ._cancellable(id: navigationID, navigationIDPath: self.navigationIDPath)
  }
}
