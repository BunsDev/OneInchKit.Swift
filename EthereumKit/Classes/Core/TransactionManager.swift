import RxSwift
import BigInt

class TransactionManager {
    private let address: Address
    private let storage: ITransactionStorage
    private let decorationManager: DecorationManager
    private let tagGenerator: TagGenerator

    private let etherTransactionsSubject = PublishSubject<[FullTransaction]>()
    private let allTransactionsSubject = PublishSubject<[FullTransaction]>()
    private let disposeBag = DisposeBag()

    var etherTransactionsObservable: Observable<[FullTransaction]> {
        etherTransactionsSubject.asObservable()
    }

    var allTransactionsObservable: Observable<[FullTransaction]> {
        allTransactionsSubject.asObservable()
    }

    init(address: Address, storage: ITransactionStorage, transactionSyncManager: TransactionSyncManager, decorationManager: DecorationManager, tagGenerator: TagGenerator) {
        self.address = address
        self.storage = storage
        self.decorationManager = decorationManager
        self.tagGenerator = tagGenerator

        transactionSyncManager
                .transactionsObservable
                .subscribeOn(ConcurrentDispatchQueueScheduler(qos: .background))
                .subscribe(
                        onNext: { [weak self] transactions in
                            self?.handle(syncedTransactions: transactions)
                        }
                )
                .disposed(by: disposeBag)
    }

    private func handle(syncedTransactions: [FullTransaction]) {
        let decoratedTransactions = syncedTransactions.map { decorationManager.decorateFullTransaction(fullTransaction: $0) }
        for transaction in decoratedTransactions {
            storage.set(tags: tagGenerator.generate(for: transaction))
        }

        if !decoratedTransactions.isEmpty {
            allTransactionsSubject.onNext(decoratedTransactions)
        }

        let etherTransactions = decoratedTransactions.filter {
            hasEtherTransferred(fullTransaction: $0)
        }

        if !etherTransactions.isEmpty {
            etherTransactionsSubject.onNext(etherTransactions)
        }
    }

    private func hasEtherTransferred(fullTransaction: FullTransaction) -> Bool {
        (fullTransaction.transaction.from == address && fullTransaction.transaction.value > 0) ||
                fullTransaction.transaction.to == address ||
                fullTransaction.internalTransactions.contains {
                    $0.to == address
                }
    }

}

extension TransactionManager {

    func etherTransferTransactionData(to: Address, value: BigUInt) -> TransactionData {
        TransactionData(
                to: to,
                value: value,
                input: Data()
        )
    }

    func etherTransactionsSingle(fromHash: Data?, limit: Int?) -> Single<[FullTransaction]> {
        storage.etherTransactionsBeforeSingle(address: address, hash: fromHash, limit: limit)
                .map { [weak self] transactions in
                    if let manager = self {
                        return transactions.map {
                            manager.decorationManager.decorateFullTransaction(fullTransaction: $0)
                        }
                    }

                    return []
                }
    }

    func transactionsSingle(tags: [[String]], fromHash: Data?, limit: Int?) -> Single<[FullTransaction]> {
        storage
                .transactionsBeforeSingle(tags: tags, hash: fromHash, limit: limit)
                .map { [weak self] transactions in
                    if let manager = self {
                        return transactions.map {
                            manager.decorationManager.decorateFullTransaction(fullTransaction: $0)
                        }
                    }

                    return []
                }
    }

    func pendingTransactions(tags: [[String]]) -> [FullTransaction] {
        storage
                .pendingTransactions(tags: tags)
                .map { transaction in
                    decorationManager.decorateFullTransaction(fullTransaction: transaction)
                }
    }

    func transactions(byHashes hashes: [Data]) -> [FullTransaction] {
        storage.fullTransactions(byHashes: hashes)
    }

    func transaction(hash: Data) -> FullTransaction? {
        storage.transaction(hash: hash)
    }

    func handle(sentTransaction: Transaction) {
        storage.save(transaction: sentTransaction)

        let fullTransaction = FullTransaction(transaction: sentTransaction)
        handle(syncedTransactions: [fullTransaction])
    }

    func transactions(fromSyncOrder: Int?) -> [FullTransaction] {
        storage.fullTransactionsAfter(syncOrder: fromSyncOrder)
    }

}
