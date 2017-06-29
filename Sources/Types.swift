import Dispatch

public enum Signal<A> {
	case next(A)
	case stop

	public func map<B>(_ transform: (A) -> B) -> Signal<B> {
		switch self {
		case .next(let value):
			return .next(transform(value))
		case .stop:
			return .stop
		}
	}
}

public protocol Producer: class {
	associatedtype ProducedType

    var productionQueue: DispatchQueue { get }
    
	@discardableResult
	func upon(_ callback: @escaping (Signal<ProducedType>) -> ()) -> Self
}

public protocol Consumer: class {
	associatedtype ConsumedType

	@discardableResult
	func receive(_ value: Signal<ConsumedType>) -> Self
}

public protocol Disconnectable {
	func disconnect()
}

public final class Wire: Disconnectable {

	private var producer: Any?
	private var consumer: Any?
    
    private var connected: Bool

	public init<P,C>(producer: P, consumer: C) where P: Producer, C: Consumer, P.ProducedType == C.ConsumedType {
		self.producer = producer
		self.consumer = consumer
        self.connected = true

        producer.upon { [weak self] signal in
            guard let this = self, this.connected else { return }
            consumer.receive(signal)
        }
	}

	public func disconnect() {
		producer = nil
		consumer = nil
        connected = false
	}
}

public final class DisconnectableBag: Disconnectable {
	private var disconnectables: [Disconnectable] = []

	public init() {}

	public func add(_ value: Disconnectable) {
		disconnectables.append(value)
	}

	public func disconnect() {
		disconnectables.forEach { $0.disconnect() }
		disconnectables.removeAll()
	}
}

extension Disconnectable {
	public func add(to bag: DisconnectableBag) {
		bag.add(self)
	}
}

extension Producer {
	public func connect<C>(to consumer: C) -> Wire where C: Consumer, C.ConsumedType == ProducedType {
		return Wire.init(producer: self, consumer: consumer)
	}
}

public final class Talker<A>: Producer {
	public typealias ProducedType = A

	private var callbacks: [(Signal<A>) -> ()] = []

    public let productionQueue: DispatchQueue
    
    public init(productionQueue: DispatchQueue = .main) {
        self.productionQueue = productionQueue
    }
    
	public func say(_ value: A) {
        callbacks.forEach { callback in
            self.productionQueue.async { callback(.next(value)) }
        }
	}

	@discardableResult
	public func mute() -> Talker<A> {
        callbacks.forEach { callback in
            self.productionQueue.async { callback(.stop) }
        }
		callbacks.removeAll()
		return self
	}

	@discardableResult
	public func upon(_ callback: @escaping (Signal<A>) -> ()) -> Talker<A> {
		callbacks.append(callback)
		return self
	}
}

public final class Listener<A>: Consumer {
	public typealias ConsumedType = A

	private let listen: (Signal<A>) -> ()

	public init(listen: @escaping (Signal<A>) -> ()) {
		self.listen = listen
	}

	@discardableResult
	public func receive(_ value: Signal<A>) -> Listener<A> {
		listen(value)
		return self
	}
}

public final class Accumulator<A>: Consumer {
	public typealias ConsumedType = A

	public private(set) var values: [A] = []

	public init() {}

	@discardableResult
	public func receive(_ signal: Signal<A>) -> Accumulator<A> {
		switch signal {
		case .next(let value):
			values.append(value)
		case .stop:
			values.removeAll()
		}
		return self
	}
}


class BoxProducerBase<Wrapped>: Producer {
	typealias ProducedType = Wrapped
    
    var productionQueue: DispatchQueue {
        fatalError()
    }

	@discardableResult
	func upon(_ callback: @escaping (Signal<Wrapped>) -> ()) -> Self {
		fatalError()
	}
}

class BoxProducer<ProducerBase: Producer>: BoxProducerBase<ProducerBase.ProducedType> {
	let base: ProducerBase
	init(base: ProducerBase) {
		self.base = base
	}

	@discardableResult
	override func upon(_ callback: @escaping (Signal<ProducerBase.ProducedType>) -> ()) -> Self {
		base.upon(callback)
		return self
	}
}

public class AnyProducer<A>: Producer {
	public typealias ProducedType = A

	fileprivate let box: BoxProducerBase<A>
    
    public var productionQueue: DispatchQueue {
        return self.box.productionQueue
    }

	public init<P: Producer>(_ base: P) where P.ProducedType == ProducedType {
		self.box = BoxProducer(base: base)
	}

	@discardableResult
	public func upon(_ callback: @escaping (Signal<A>) -> ()) -> Self {
		box.upon(callback)
		return self
	}
}

class BoxConsumerBase<Wrapped>: Consumer {
    typealias ConsumedType = Wrapped
    
    var productionQueue: DispatchQueue {
        fatalError()
    }
    
    @discardableResult
    func receive(_ value: Signal<Wrapped>) -> Self {
        fatalError()
    }
}

class BoxConsumer<ConsumerBase: Consumer>: BoxConsumerBase<ConsumerBase.ConsumedType> {
    let base: ConsumerBase
    init(base: ConsumerBase) {
        self.base = base
    }
    
    @discardableResult
    override func receive(_ value: Signal<ConsumerBase.ConsumedType>) -> Self {
        base.receive(value)
        return self
    }
}

public class AnyConsumer<A>: Consumer {
    public typealias ConsumedType = A
    
    fileprivate let box: BoxConsumerBase<A>
    
    public init<C: Consumer>(_ base: C) where C.ConsumedType == ConsumedType {
        self.box = BoxConsumer(base: base)
    }
    
    @discardableResult
    public func receive(_ value: Signal<A>) -> Self {
        box.receive(value)
        return self
    }
}

public final class ConstantProducer<Wrapped>: Producer {
    public typealias ProducedType = Wrapped
    
    public var productionQueue: DispatchQueue
    private let value: Wrapped
    
    public init(_ value: Wrapped, productionQueue: DispatchQueue = .main) {
        self.value = value
        self.productionQueue = productionQueue
    }
    
    @discardableResult
    public func upon(_ callback: @escaping (Signal<Wrapped>) -> ()) -> Self {
        productionQueue.async { callback(.next(self.value)) }
        return self
    }
}

public protocol Transformer: Producer {
	associatedtype TransformedType
	func transform(_ value: Signal<TransformedType>) -> (@escaping (Signal<ProducedType>) -> ()) -> ()
}

open class AbstractTransformer<Source,Target>: Transformer {
	public typealias TransformedType = Source
	public typealias ProducedType = Target

	private let roots: [AnyProducer<Source>]
    let transformationQueue: DispatchQueue
    public let productionQueue: DispatchQueue
    private let talker: Talker<Target>
    private lazy var listener: Listener<Source> = Listener<Source>.init(listen: { [weak self] signal in
        guard let this = self else { return }
        this.transformationQueue.async {
            let call = this.transform(signal)
            call { newSignal in
                switch newSignal {
                case .next(let value):
                    this.talker.say(value)
                case .stop:
                    this.talker.mute()
                }
            }
        }
    })

	public init<P>(_ roots: [P], transformationQueue: DispatchQueue, productionQueue: DispatchQueue) where P: Producer, P.ProducedType == Source {
		self.roots = roots.map(AnyProducer.init)
		self.transformationQueue = transformationQueue
        self.productionQueue = productionQueue
        self.talker = Talker<Target>.init(productionQueue: productionQueue)
        for root in roots {
            root.upon { [weak self] signal in self?.listener.receive(signal) }
        }
	}

    @discardableResult
	public func upon(_ callback: @escaping (Signal<Target>) -> ()) -> Self {
		self.talker.upon(callback)
		return self
	}

	public func transform(_ value: Signal<Source>) -> (@escaping (Signal<Target>) -> ()) -> () {
		fatalError("\(self): transform(_:) not implemented")
	}
}

public final class MapProducer<Source,Target>: AbstractTransformer<Source,Target> {
	private let mappingFunction: (Source) -> Target

	public init<P>(_ root: P, queue: DispatchQueue, mappingFunction: @escaping (Source) -> Target) where P: Producer, P.ProducedType == Source {
		self.mappingFunction = mappingFunction
		super.init([root], transformationQueue: queue, productionQueue: root.productionQueue)
	}

	public override func transform(_ signal: Signal<Source>) -> (@escaping (Signal<Target>) -> ()) -> () {
		return { [weak self] done in
            guard let this = self else { return }
            done(signal.map(this.mappingFunction))
        }
	}
}

public final class FlatMapProducer<Source,Target>: AbstractTransformer<Source,Target> {
	private let flatMappingFunction: (Source) -> AnyProducer<Target>
    private var newProducers: [Int : AnyProducer<Target>] = [:]
    private var currentIndex = 0

	public init<P>(_ root: P, queue: DispatchQueue, flatMappingFunction: @escaping (Source) -> AnyProducer<Target>) where P: Producer, P.ProducedType == Source {
		self.flatMappingFunction = flatMappingFunction
		super.init([root], transformationQueue: queue, productionQueue: root.productionQueue)
	}

	public override func transform(_ signal: Signal<Source>) -> (@escaping (Signal<Target>) -> ()) -> () {
		return { [weak self] done in
            guard let this = self else { return }
            switch signal {
            case .next(let value):
                let newProducer = this.flatMappingFunction(value)
                this.currentIndex += 1
                let newIndex = this.currentIndex
                this.newProducers[newIndex] = newProducer
                newProducer.upon(done)
                newProducer.upon { [weak this] newSignal in
                    switch newSignal {
                    case .stop:
                        this?.newProducers[newIndex] = nil
                    case .next:
                        break
                    }
                }
            case .stop:
                this.newProducers.removeAll()
                done(.stop)
            }
        }
	}
}

public final class FilterProducer<Wrapped>: AbstractTransformer<Wrapped,Wrapped> {
    private let conditionFunction: (Wrapped) -> Bool
    
    public init<P>(_ root: P, queue: DispatchQueue, conditionFunction: @escaping (Wrapped) -> Bool) where P: Producer, P.ProducedType == Wrapped {
        self.conditionFunction = conditionFunction
        super.init([root], transformationQueue: queue, productionQueue: root.productionQueue)
    }
    
    public override func transform(_ signal: Signal<Wrapped>) -> (@escaping (Signal<Wrapped>) -> ()) -> () {
        return { [weak self] done in
            guard let this = self else { return }
            switch signal {
            case .next(let value):
                if this.conditionFunction(value) { done(.next(value)) }
            case .stop:
                done(.stop)
            }
        }
    }
}

public final class MergeProducer<Wrapped>: AbstractTransformer<Wrapped,Wrapped> {
    public init<P>(_ root: P, queue: DispatchQueue, other: P) where P:Producer, P.ProducedType == Wrapped {
        super.init([root, other], transformationQueue: queue, productionQueue: DispatchQueue.main)
    }
    
    public override func transform(_ signal: Signal<Wrapped>) -> (@escaping (Signal<Wrapped>) -> ()) -> () {
        return { [weak self] done in
            guard self != nil else { return }
            done(signal)
        }
    }
}

public final class DebounceProducer<Wrapped>: AbstractTransformer<Wrapped,Wrapped> {
	private let delay: Double
	private var currentSignalId: Int = 0

	public init<P>(_ root: P, queue: DispatchQueue, delay: Double) where P: Producer, P.ProducedType == Wrapped {
		self.delay = delay
		super.init([root], transformationQueue: queue, productionQueue: root.productionQueue)
	}

	public override func transform(_ signal: Signal<Wrapped>) -> (@escaping (Signal<Wrapped>) -> ()) -> () {
		currentSignalId += 1
		let expectedSignalId = currentSignalId
		return { [weak self] done in
            guard let this = self else { return }
            switch signal {
            case .next(let value):
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

public final class CachedProducer<Wrapped>: AbstractTransformer<Wrapped,Wrapped> {
    private var constant: ConstantProducer<Wrapped>? = nil
    
    public init<P>(_ root: P, queue: DispatchQueue) where P:Producer, P.ProducedType == Wrapped {
        super.init([root], transformationQueue: queue, productionQueue: root.productionQueue)
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
            constant = ConstantProducer.init(value, productionQueue: productionQueue)
        case .stop:
            constant = nil
        }
    }
}

extension Producer {
	public func consume(_ callback: @escaping (ProducedType) -> ()) -> Wire {
		var toDisconnect: Wire? = nil
		let disconnectable = connect(to: Listener.init { signal in
			switch signal {
			case .next(let value):
				callback(value)
			case .stop:
				toDisconnect?.disconnect()
			}
		})
		toDisconnect = disconnectable
		return disconnectable
	}

	public var any: AnyProducer<ProducedType> {
		return AnyProducer(self)
	}

	public func map<A>(on queue: DispatchQueue = .main, _ transform: @escaping (ProducedType) -> A) -> MapProducer<ProducedType,A> {
		return MapProducer<ProducedType,A>.init(self, queue: queue, mappingFunction: transform)
	}

	public func flatMap<A>(on queue: DispatchQueue = .main, _ transform: @escaping (ProducedType) -> AnyProducer<A>) -> FlatMapProducer<ProducedType,A> {
		return FlatMapProducer<ProducedType,A>.init(self, queue: queue, flatMappingFunction: transform)
	}

	public func debounce(on queue: DispatchQueue = .main, _ delay: Double) -> DebounceProducer<ProducedType> {
		return DebounceProducer<ProducedType>.init(self, queue: queue, delay: delay)
	}
    
    public func filter(on queue: DispatchQueue = .main, _ predicate: @escaping (ProducedType) -> Bool) -> FilterProducer<ProducedType> {
        return FilterProducer<ProducedType>.init(self, queue: queue, conditionFunction: predicate)
    }
    
    public func cached(on queue: DispatchQueue = .main) -> CachedProducer<ProducedType> {
        return CachedProducer<ProducedType>.init(self, queue: queue)
    }
    
    public func merge<P>(on queue: DispatchQueue = .main, _ other: P) -> MergeProducer<ProducedType> where P:Producer, P.ProducedType == ProducedType {
        return MergeProducer<ProducedType>.init(AnyProducer(self), queue: queue, other: AnyProducer(other))
    }
    
    public func mapSome<A>(on queue: DispatchQueue = .main, _ transform: @escaping (ProducedType) -> A?) -> MapProducer<A?,A> {
        return map(transform)
            .filter { $0 != nil }
            .map { $0! }
    }
}


