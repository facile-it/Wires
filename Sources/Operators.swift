import Dispatch

open class AbstractTransformer<Source,Target>: Transformer {
    public typealias TransformedType = Source
    public typealias ProducedType = Target
    
	public let transformationQueue: DispatchQueue
	public let productionQueue: DispatchQueue

	private let roots: [AnyProducer<Source>]
    private let speaker: Speaker<Target>
    private lazy var listener: Listener<Source> = Listener<Source>.init(listen: { [weak self] signal in
        guard let this = self else { return }
        this.transformationQueue.async {
			Log.with(context: this, text: "transforming on \(this.transformationQueue)")
            let call = this.transform(signal)
            call { newSignal in
				Log.with(context: this, text: "got new signal \(newSignal)")
                switch newSignal {
                case .next(let value):
                    this.speaker.say(value)
                case .stop:
                    this.speaker.mute()
                }
            }
        }
    })
    
    public init<P>(_ roots: [P], transformationQueue: DispatchQueue, productionQueue: DispatchQueue) where P: Producer, P.ProducedType == Source {
        self.roots = roots.map(AnyProducer.init)
        self.transformationQueue = transformationQueue
        self.productionQueue = productionQueue
        self.speaker = Speaker<Target>.init(productionQueue: productionQueue)
		Log.with(context: self, text: "init with roots \(roots)")
        for root in roots {
            root.upon { [weak self] signal in self?.listener.receive(signal) }
        }
    }
    
    @discardableResult
    public func upon(_ callback: @escaping (Signal<Target>) -> ()) -> Self {
        self.speaker.upon(callback)
        return self
    }
    
    public func transform(_ value: Signal<Source>) -> (@escaping (Signal<Target>) -> ()) -> () {
        fatalError("\(self): transform(_:) not implemented")
    }
}

// MARK: -

public final class MapProducer<Source,Target>: AbstractTransformer<Source,Target> {
    private let mappingFunction: (Source) -> Target
    
    public init<P>(_ root: P, queue: DispatchQueue?, mappingFunction: @escaping (Source) -> Target) where P: Producer, P.ProducedType == Source {
        self.mappingFunction = mappingFunction
		let transformationQueue = queue ?? (root as? TransformationQueueOwner)?.transformationQueue ?? .main
        super.init([root], transformationQueue: transformationQueue, productionQueue: root.productionQueue)
    }
    
    public override func transform(_ signal: Signal<Source>) -> (@escaping (Signal<Target>) -> ()) -> () {
        return { [weak self] done in
            guard let this = self else { return }
			Log.with(context: this, text: "mapping \(signal)")
            done(signal.map(this.mappingFunction))
        }
    }
}

// MARK: -

public final class FlatMapProducer<Source,Target>: AbstractTransformer<Source,Target> {
    private let flatMappingFunction: (Source) -> AnyProducer<Target>
    private var newProducers: [Int : AnyProducer<Target>] = [:]
    private var currentIndex = 0
    
    public init<P>(_ root: P, queue: DispatchQueue?, flatMappingFunction: @escaping (Source) -> AnyProducer<Target>) where P: Producer, P.ProducedType == Source {
        self.flatMappingFunction = flatMappingFunction
		let transformationQueue = queue ?? (root as? TransformationQueueOwner)?.transformationQueue ?? .main
        super.init([root], transformationQueue: transformationQueue, productionQueue: root.productionQueue)
    }
    
    public override func transform(_ signal: Signal<Source>) -> (@escaping (Signal<Target>) -> ()) -> () {
        return { [weak self] done in
            guard let this = self else { return }
			Log.with(context: this, text: "flatMapping \(signal)")
            switch signal {
            case .next(let value):
				Log.with(context: this, text: "creating new producer from \(value)")
                let newProducer = this.flatMappingFunction(value)
                this.currentIndex += 1
                let newIndex = this.currentIndex
                this.newProducers[newIndex] = newProducer
                newProducer.upon(done)
                newProducer.upon { [weak this] newSignal in
					guard let this = this else { return }
					Log.with(context: this, text: "produced from flatMap: \(signal)")
                    switch newSignal {
                    case .stop:
                        this.newProducers[newIndex] = nil
                    case .next:
                        break
                    }
                }
            case .stop:
				Log.with(context: this, text: "removing all producers")
                this.newProducers.removeAll()
                done(.stop)
            }
        }
    }
}

// MARK: -

public final class FilterProducer<Wrapped>: AbstractTransformer<Wrapped,Wrapped> {
    private let conditionFunction: (Wrapped) -> Bool
    
    public init<P>(_ root: P, queue: DispatchQueue?, conditionFunction: @escaping (Wrapped) -> Bool) where P: Producer, P.ProducedType == Wrapped {
        self.conditionFunction = conditionFunction
		let transformationQueue = queue ?? (root as? TransformationQueueOwner)?.transformationQueue ?? .main
        super.init([root], transformationQueue: transformationQueue, productionQueue: root.productionQueue)
    }
    
    public override func transform(_ signal: Signal<Wrapped>) -> (@escaping (Signal<Wrapped>) -> ()) -> () {
        return { [weak self] done in
            guard let this = self else { return }
            switch signal {
            case .next(let value):
                if this.conditionFunction(value) {
					Log.with(context: this, text: "filtering passed for \(value)")
					done(.next(value))
				} else {
					Log.with(context: this, text: "filtering NOT passed for \(value)")
				}
            case .stop:
                done(.stop)
            }
        }
    }
}

// MARK: -

public final class MergeProducer<Wrapped>: AbstractTransformer<Wrapped,Wrapped> {
    public init<P>(_ root: P, queue: DispatchQueue?, other: P) where P: Producer, P.ProducedType == Wrapped {
		let transformationQueue = queue ?? (root as? TransformationQueueOwner)?.transformationQueue ?? .main
        super.init([root, other], transformationQueue: transformationQueue, productionQueue: DispatchQueue.main)
    }
    
    public override func transform(_ signal: Signal<Wrapped>) -> (@escaping (Signal<Wrapped>) -> ()) -> () {
        return { [weak self] done in
            guard self != nil else { return }
            done(signal)
        }
    }
}

// MARK: -

public final class DebounceProducer<Wrapped>: AbstractTransformer<Wrapped,Wrapped> {
    private let delay: Double
    private var currentSignalId: Int = 0
    
    public init<P>(_ root: P, queue: DispatchQueue?, delay: Double) where P: Producer, P.ProducedType == Wrapped {
        self.delay = delay
		let transformationQueue = queue ?? (root as? TransformationQueueOwner)?.transformationQueue ?? .main
        super.init([root], transformationQueue: transformationQueue, productionQueue: root.productionQueue)
    }
    
    public override func transform(_ signal: Signal<Wrapped>) -> (@escaping (Signal<Wrapped>) -> ()) -> () {
        currentSignalId += 1
        let expectedSignalId = currentSignalId
        return { [weak self] done in
            guard let this = self else { return }
            switch signal {
            case .next(let value):
				Log.with(context: this, text: "delaying \(value) for \(this.delay) seconds")
                this.transformationQueue.asyncAfter(deadline: .now() + this.delay, execute: {
                    guard this.currentSignalId == expectedSignalId else { return }
                    done(.next(value))
                })
            case .stop:
                done(.stop)
            }
        }
    }
}

// MARK: -

public final class CachedProducer<Wrapped>: AbstractTransformer<Wrapped,Wrapped> {
    private var constant: Fixed<Wrapped>? = nil
    
    public init<P>(_ root: P, queue: DispatchQueue?) where P:Producer, P.ProducedType == Wrapped {
		let transformationQueue = queue ?? (root as? TransformationQueueOwner)?.transformationQueue ?? .main
        super.init([root], transformationQueue: transformationQueue, productionQueue: root.productionQueue)
        root.upon { [weak self] signal in
            guard let this = self else { return }
            this.receiveConstant(with: signal)
        }
    }
    
    public override func transform(_ signal: Signal<Wrapped>) -> (@escaping (Signal<Wrapped>) -> ()) -> () {
        return { [weak self] done in
            guard let this = self else { return }
            this.receiveConstant(with: signal)
            done(signal)
        }
    }
    
    @discardableResult
    public override func upon(_ callback: @escaping (Signal<Wrapped>) -> ()) -> Self {
        constant?.upon(callback)
        super.upon(callback)
        return self
    }
    
    private func receiveConstant(with signal: Signal<Wrapped>) {
        switch signal {
        case .next(let value):
			Log.with(context: self, text: "caching \(value)")
            constant = Fixed.init(value, productionQueue: productionQueue)
        case .stop:
            constant = nil
        }
    }
}

// MARK: -

public final class SideEffectProducer<Wrapped>: AbstractTransformer<Wrapped,Wrapped> {
	private let sideEffectFunction: (Signal<Wrapped>) -> ()

	public init<P>(_ root: P, queue: DispatchQueue?, sideEffectFunction: @escaping (Signal<Wrapped>) -> ()) where P: Producer, P.ProducedType == Wrapped {
		self.sideEffectFunction = sideEffectFunction
		let transformationQueue = queue ?? (root as? TransformationQueueOwner)?.transformationQueue ?? .main
		super.init([root], transformationQueue: transformationQueue, productionQueue: root.productionQueue)
	}

	public override func transform(_ signal: Signal<Wrapped>) -> (@escaping (Signal<Wrapped>) -> ()) -> () {
		return { [weak self] done in
			guard let this = self else { return }
			Log.with(context: this, text: "side effect from \(signal)")
			this.sideEffectFunction(signal)
			done(signal)
		}
	}
}

// MARK: -

public final class SwitchQueueProducer<Wrapped>: AbstractTransformer<Wrapped,Wrapped> {
	public init<P>(_ root: P, newTransformationQueue: DispatchQueue? = nil, newProductionQueue: DispatchQueue? = nil) where P: Producer, P.ProducedType == Wrapped {
		let transformationQueue = newTransformationQueue ?? (root as? TransformationQueueOwner)?.transformationQueue ?? .main
		let productionQueue = newProductionQueue ?? root.productionQueue
		super.init([root], transformationQueue: transformationQueue, productionQueue: productionQueue)
	}

	public override func transform(_ signal: Signal<Wrapped>) -> (@escaping (Signal<Wrapped>) -> ()) -> () {
		return { $0(signal) }
	}
}

// MARK: - Producer methods

extension Producer {
	public func map<A>(on queue: DispatchQueue? = nil, _ transform: @escaping (ProducedType) -> A) -> MapProducer<ProducedType,A> {
		return MapProducer<ProducedType,A>.init(self, queue: queue, mappingFunction: transform)
	}

	public func flatMap<A>(on queue: DispatchQueue? = nil, _ transform: @escaping (ProducedType) -> AnyProducer<A>) -> FlatMapProducer<ProducedType,A> {
		return FlatMapProducer<ProducedType,A>.init(self, queue: queue, flatMappingFunction: transform)
	}

	public func debounce(on queue: DispatchQueue? = nil, _ delay: Double) -> DebounceProducer<ProducedType> {
		return DebounceProducer<ProducedType>.init(self, queue: queue, delay: delay)
	}

	public func filter(on queue: DispatchQueue? = nil, _ predicate: @escaping (ProducedType) -> Bool) -> FilterProducer<ProducedType> {
		return FilterProducer<ProducedType>.init(self, queue: queue, conditionFunction: predicate)
	}

	public func cached(on queue: DispatchQueue? = nil) -> CachedProducer<ProducedType> {
		return CachedProducer<ProducedType>.init(self, queue: queue)
	}

	public func merge<P>(on queue: DispatchQueue? = nil, _ other: P) -> MergeProducer<ProducedType> where P:Producer, P.ProducedType == ProducedType {
		return MergeProducer<ProducedType>.init(AnyProducer(self), queue: queue, other: AnyProducer(other))
	}

	public func sideEffect(on queue: DispatchQueue? = nil, _ effect: @escaping (Signal<ProducedType>) -> ()) -> SideEffectProducer<ProducedType> {
		return SideEffectProducer<ProducedType>.init(self, queue: queue, sideEffectFunction: effect)
	}

	public func produce(on queue: DispatchQueue) -> SwitchQueueProducer<ProducedType> {
		return SwitchQueueProducer.init(self, newTransformationQueue: nil, newProductionQueue: queue)
	}

	public func transform(on queue: DispatchQueue) -> SwitchQueueProducer<ProducedType> {
		return SwitchQueueProducer.init(self, newTransformationQueue: queue, newProductionQueue: nil)
	}

	// MARK: - Convenience

	public func mapSome<A>(on queue: DispatchQueue? = nil, _ transform: @escaping (ProducedType) -> A?) -> MapProducer<A?,A> {
		return map(on: queue, transform)
			.filter(on: queue) { $0 != nil }
			.map { $0! }
	}

	public func sideEffectOnNext(on queue: DispatchQueue? = nil, _ effect: @escaping (ProducedType) -> ()) -> SideEffectProducer<ProducedType> {
		return SideEffectProducer<ProducedType>.init(self, queue: queue, sideEffectFunction: { guard case .next(let value) = $0 else { return }; effect(value) })
	}

	public func sideEffectOnStop(on queue: DispatchQueue? = nil, _ effect: @escaping () -> ()) -> SideEffectProducer<ProducedType> {
		return SideEffectProducer<ProducedType>.init(self, queue: queue, sideEffectFunction: { guard case .stop = $0 else { return }; effect() })
	}
}
