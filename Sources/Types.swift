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

	@discardableResult
	func upon(_ callback: @escaping (Signal<ProducedType>) -> ()) -> Self
}

public protocol Consumer: class {
	associatedtype ConsumedType

	@discardableResult
	func update(_ value: Signal<ConsumedType>) -> Self
}

public final class Wire {

	private var producer: Any?
	private var consumer: Any?

	public init<P,C>(producer: P, consumer: C) where P: Producer, C: Consumer, P.ProducedType == C.ConsumedType {
		self.producer = producer
		self.consumer = consumer

		producer.upon { consumer.update($0) }
	}

	public func disconnect() {
		producer = nil
		consumer = nil
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

	public func say(_ value: A) {
		callbacks.forEach { $0(.next(value)) }
	}

	@discardableResult
	public func mute() -> Talker<A> {
		callbacks.forEach { $0(.stop) }
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
	public func update(_ value: Signal<A>) -> Listener<A> {
		listen(value)
		return self
	}
}

class BoxProducerBase<Wrapped>: Producer {
	typealias ProducedType = Wrapped

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

	public init<P: Producer>(_ base: P) where P.ProducedType == ProducedType {
		self.box = BoxProducer(base: base)
	}

	@discardableResult
	public func upon(_ callback: @escaping (Signal<A>) -> ()) -> Self {
		box.upon(callback)
		return self
	}
}

public protocol Transformer: Producer {
	associatedtype TransformedType
	func transform(_ value: TransformedType) -> (@escaping (Signal<ProducedType>) -> ()) -> ()
}

open class AbstractTransformer<Source,Target>: Transformer {
	public typealias TransformedType = Source
	public typealias ProducedType = Target

	private let root: AnyProducer<Source>
	let queue: DispatchQueue
	private let talker: Talker<Target>
	private lazy var listener: Listener<Source> = Listener<Source>.init(listen: { [weak self] signal in
		guard let this = self else { return }
		switch signal {
		case .next(let value):
			let call = this.transform(value)
			call { newSignal in
				switch newSignal {
				case .next(let value):
					this.talker.say(value)
				case .stop:
					this.talker.mute()
				}
			}
		case .stop:
			this.talker.mute()
		}
	})

	public init<P>(_ root: P, queue: DispatchQueue) where P: Producer, P.ProducedType == Source {
		self.root = AnyProducer.init(root)
		self.queue = queue
		self.talker = Talker<Target>.init()
		self.root.upon { [weak self] signal in self?.listener.update(signal) }
	}

	public func upon(_ callback: @escaping (Signal<Target>) -> ()) -> Self {
		self.talker.upon(callback)
		return self
	}

	public func transform(_ value: Source) -> (@escaping (Signal<Target>) -> ()) -> () {
		fatalError("\(self): transform(_:) not implemented")
	}
}

public final class MapProducer<Source,Target>: AbstractTransformer<Source,Target> {
	private let mappingFunction: (Source) -> Target

	public init<P>(_ root: P, queue: DispatchQueue, mappingFunction: @escaping (Source) -> Target) where P: Producer, P.ProducedType == Source {
		self.mappingFunction = mappingFunction
		super.init(root, queue: queue)
	}

	public override func transform(_ value: Source) -> (@escaping (Signal<Target>) -> ()) -> () {
		return { [weak self] done in
			guard let this = self else { return }
			this.queue.async {
				done(.next(this.mappingFunction(value)))
			}
		}
	}
}

public final class FlatMapProducer<Source,Target>: AbstractTransformer<Source,Target> {
	private let flatMappingFunction: (Source) -> AnyProducer<Target>

	public init<P>(_ root: P, queue: DispatchQueue, flatMappingFunction: @escaping (Source) -> AnyProducer<Target>) where P: Producer, P.ProducedType == Source {
		self.flatMappingFunction = flatMappingFunction
		super.init(root, queue: queue)
	}

	public override func transform(_ value: Source) -> (@escaping (Signal<Target>) -> ()) -> () {
		return { [weak self] done in
			guard let this = self else { return }
			this.queue.async {
				this.flatMappingFunction(value).upon(done)
			}
		}
	}
}

public final class DebounceProducer<Wrapped>: AbstractTransformer<Wrapped,Wrapped> {
	private let delay: Double
	private var currentSignalId: Int = 0

	public init<P>(_ root: P, queue: DispatchQueue, delay: Double) where P: Producer, P.ProducedType == Wrapped {
		self.delay = delay
		super.init(root, queue: queue)
	}

	public override func transform(_ value: Wrapped) -> (@escaping (Signal<Wrapped>) -> ()) -> () {
		currentSignalId += 1
		let expectedSignalId = currentSignalId
		return { [weak self] done in
			guard let this = self else { return }
			this.queue.asyncAfter(deadline: .now() + this.delay, execute: {
				guard this.currentSignalId == expectedSignalId else { return }
				done(.next(value))
			})
		}
	}
}

extension Producer {
	public var any: AnyProducer<ProducedType> {
		return AnyProducer(self)
	}

	public func map<A>(on queue: DispatchQueue = .main, transform: @escaping (ProducedType) -> A) -> MapProducer<ProducedType,A> {
		return MapProducer<ProducedType,A>.init(self, queue: queue, mappingFunction: transform)
	}

	public func flatMap<A>(on queue: DispatchQueue = .main, transform: @escaping (ProducedType) -> AnyProducer<A>) -> FlatMapProducer<ProducedType,A> {
		return FlatMapProducer<ProducedType,A>.init(self, queue: queue, flatMappingFunction: transform)
	}

	public func debounce(on queue: DispatchQueue = .main, delay: Double) -> DebounceProducer<ProducedType> {
		return DebounceProducer<ProducedType>.init(self, queue: queue, delay: delay)
	}
}
